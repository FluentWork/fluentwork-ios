import FactoryKit
import FluentWorkNetworking
import Foundation
import Testing
import TGReduxKit
@testable import FluentWorkCore

@Suite("SpeechSessionMiddleware forceClose")
struct ForceCloseMiddlewareTests {

    @MainActor
    @Test func forceCloseFromConnectingEndsSessionAndClosesTransport() async throws {
        let container = Container()
        container.reset()
        let audioEngine = StubAudioEngineForForceClose()
        let speechClient = StubSpeechSessionClientForForceClose()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }
        container.backgroundTaskPort.register { NoOpBackgroundTaskPort() }

        let store = AppStoreFactory.make(container: container)
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)

        store.dispatch(.speakingRoom(.session(.forceClose)))
        try await waitForPhase(store, phase: .ended, timeout: 1_000_000_000)

        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            let ended = await speechClient.endSessionCalled
            let closed = await speechClient.closeTransportCalled
            let stopped = await audioEngine.stopCaptureCalled
            let released = await audioEngine.releaseSessionClaimCalled
            return ended && closed && stopped && released
        }

        #expect(await speechClient.endSessionCalled)
        #expect(await speechClient.closeTransportCalled)
        #expect(await audioEngine.stopCaptureCalled)
        // 进后台是「显式结束会话」那一类，所以共享会话也要还回去 —— 否则 App 退到后台后
        // 仍永久占着音频会话（别的 App 的声音再也回不来）。
        #expect(await audioEngine.releaseSessionClaimCalled)
        #expect(store.state.speakingRoom.phase == .ended)
    }

    @MainActor
    @Test func forceCloseFromIdleDoesNotEndSession() async throws {
        let container = Container()
        container.reset()
        let audioEngine = StubAudioEngineForForceClose()
        let speechClient = StubSpeechSessionClientForForceClose()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }
        container.backgroundTaskPort.register { NoOpBackgroundTaskPort() }

        let store = AppStoreFactory.make(container: container)
        store.dispatch(.speakingRoom(.session(.forceClose)))

        try await Task.sleep(for: .milliseconds(200))

        #expect(await speechClient.endSessionCalled == false)
        #expect(await speechClient.closeTransportCalled == false)
        #expect(await audioEngine.stopCaptureCalled == false)
        #expect(await audioEngine.releaseSessionClaimCalled == false)
        #expect(store.state.speakingRoom.phase == .idle)
    }
}

// MARK: - Stubs

private final class StubAudioEngineForForceClose: AudioEngineProtocol, @unchecked Sendable {
    private let stream: AsyncStream<AudioEngineEvent>
    private let continuation: AsyncStream<AudioEngineEvent>.Continuation
    private let _stopCaptureCalled = AsyncValue(false)
    var stopCaptureCalled: Bool { get async { await _stopCaptureCalled.get() } }
    private let _releaseSessionClaimCalled = AsyncValue(false)
    var releaseSessionClaimCalled: Bool { get async { await _releaseSessionClaimCalled.get() } }

    init() {
        let pair = AsyncStream.makeStream(of: AudioEngineEvent.self)
        self.stream = pair.stream
        self.continuation = pair.continuation
    }

    func startCapture() async throws {}
    func stopCapture() async { await _stopCaptureCalled.set(true) }
    func releaseSessionClaim() async { await _releaseSessionClaimCalled.set(true) }
    func play(pcm: Data) async {}
    func interruptNow() async {}
    func discardActiveSpeech() async {}
    func events() -> AsyncStream<AudioEngineEvent> { stream }
}

private final class StubSpeechSessionClientForForceClose: SpeechSessionClientProtocol, @unchecked Sendable {
    private let stream: AsyncStream<SocketTransportEvent>
    private let continuation: AsyncStream<SocketTransportEvent>.Continuation
    private let _endSessionCalled = AsyncValue(false)
    private let _closeTransportCalled = AsyncValue(false)

    var endSessionCalled: Bool { get async { await _endSessionCalled.get() } }
    var closeTransportCalled: Bool { get async { await _closeTransportCalled.get() } }

    init() {
        let pair = AsyncStream.makeStream(of: SocketTransportEvent.self)
        self.stream = pair.stream
        self.continuation = pair.continuation
    }

    func startSession(continueFromSessionID: String?, creation: PracticeCreation?) async throws {}
    func activeSessionID() async -> String? { nil }
    func sendSpeechBoundary(started: Bool, turnID: String?, text: String?) async throws {}
    func sendTurnAbort(turnID: String, outcome: TurnOutcome) async throws {}
    func sendAudioPCM(_ data: Data) async throws {}
    func sendInterrupt() async {}
    func sendRescueRequest() async {}
    func transportEvents() -> AsyncStream<SocketTransportEvent> { stream }
    func pollReview(sessionID: String) async throws -> ReviewPollResponse {
        ReviewPollResponse(sessionID: sessionID, status: .pending, review: nil)
    }
    func sendDegradedTextMessage(_ text: String) async throws -> PostMessageResponse {
        PostMessageResponse(sessionID: "s-1", reply: "", channel: "text", generator: "stub")
    }
    func endSession() async {
        await _endSessionCalled.set(true)
        continuation.finish()
    }
    func closeTransport() async {
        await _closeTransportCalled.set(true)
        continuation.finish()
    }
}

private actor AsyncValue<T: Sendable> {
    private var stored: T
    init(_ initial: T) { stored = initial }
    func get() -> T { stored }
    func set(_ newValue: T) { stored = newValue }
}

@MainActor
private func waitForPhase(
    _ store: Store<AppState, AppAction>,
    phase: SpeechSessionPhase,
    timeout: UInt64
) async throws {
    try await waitUntil(timeoutNanoseconds: timeout) {
        store.state.speakingRoom.phase == phase
    }
}
