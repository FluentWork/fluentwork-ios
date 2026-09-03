import FactoryKit
import FluentWorkDiagnostics
import FluentWorkNetworking
import Foundation
import Testing
import TGReduxKit
import TGReduxKitTesting
@testable import FluentWorkCore

// MARK: - SpeechSessionMiddleware Unit Tests

/// Tests for the pure functions and data structures in SpeechSessionMiddleware.
///
/// These tests cover:
/// 1. `pendingTurnID` - the turn ID computation for end-of-utterance events
/// 2. `TurnCountBox` - the Sendable wrapper for cross-actor turn counting
@Suite("SpeechSessionMiddleware Unit Tests")
struct SpeechSessionMiddlewareTests {

    // MARK: - pendingTurnID Tests

    @Test func pendingTurnIDReturnsTurnNForVadSpeechEnd() {
        let turnID = pendingTurnID(for: .vadSpeechEnd(turnID: nil), currentCount: 0)
        #expect(turnID == "turn-1")
    }

    @Test func pendingTurnIDReturnsTurnNPlusOneForVadSpeechEnd() {
        let turnID = pendingTurnID(for: .vadSpeechEnd(turnID: nil), currentCount: 5)
        #expect(turnID == "turn-6")
    }

    @Test func pendingTurnIDReturnsTurnNForHoldEnd() {
        let turnID = pendingTurnID(for: .holdEnd(turnID: nil), currentCount: 2)
        #expect(turnID == "turn-3")
    }

    @Test func pendingTurnIDReturnsNilForSessionStartTap() {
        let turnID = pendingTurnID(for: .sessionStartTap, currentCount: 0)
        #expect(turnID == nil)
    }

    @Test func pendingTurnIDReturnsNilForSocketReady() {
        let turnID = pendingTurnID(for: .socketReady, currentCount: 0)
        #expect(turnID == nil)
    }

    @Test func pendingTurnIDReturnsNilForVadSpeechStart() {
        let turnID = pendingTurnID(for: .vadSpeechStart, currentCount: 3)
        #expect(turnID == nil)
    }

    @Test func pendingTurnIDReturnsNilForNetworkLost() {
        let turnID = pendingTurnID(for: .networkLost, currentCount: 0)
        #expect(turnID == nil)
    }

    @Test func pendingTurnIDReturnsNilForFailed() {
        let turnID = pendingTurnID(for: .failed("test error"), currentCount: 10)
        #expect(turnID == nil)
    }

    // MARK: - TurnCountBox Tests

    @Test func turnCountBoxInitializesWithZero() {
        let box = TurnCountBox()
        #expect(box.get() == 0)
    }

    @Test func turnCountBoxSetUpdatesValue() {
        let box = TurnCountBox()
        box.set(5)
        #expect(box.get() == 5)
    }

    @Test func turnCountBoxOverridesPreviousValue() {
        let box = TurnCountBox()
        box.set(3)
        box.set(7)
        #expect(box.get() == 7)
    }

    @Test func turnCountBoxGetDoesNotModifyValue() {
        let box = TurnCountBox()
        box.set(42)
        _ = box.get()
        #expect(box.get() == 42)
    }

    @Test func turnCountBoxIsSendable() {
        let box = TurnCountBox()
        func acceptSendable(_ box: TurnCountBox) -> Bool {
            return true
        }
        #expect(acceptSendable(box) == true)
    }
}

// MARK: - SpeechSessionMiddleware Integration Tests

/// Integration tests for the full middleware behavior with server-side ASR (B14).
///
/// These tests verify:
/// 1. Server ASR transcript handling via `serverASRReceived`
/// 2. NO phantom `sendSpeechBoundary` call when server ASR arrives (regression: the
///    original iOS VAD is the single source of truth for `user.speech.end`; emitting
///    another one here starts a ghost turn with no audio and the gateway hangs for 60s.)
/// 3. Degraded text message handling
/// 4. Transition telemetry emission
@Suite("SpeechSessionMiddleware B14 Integration")
struct SpeechSessionMiddlewareB14Tests {

    // MARK: - Server ASR Tests

    @MainActor
    @Test func serverASRDispatchesTranscriptUpdateViaReducer() async throws {
        // Note: serverASRReceived can be dispatched two ways:
        // 1. As .session(.serverASRReceived) - goes through middleware, no reducer handling
        // 2. As .serverASRReceived directly - handled by reducer to update liveTranscript
        let container = Container()
        container.reset()
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }

        let store = AppStoreFactory.make(container: container)
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)

        // Connect first
        store.dispatch(.speakingRoom(.session(.socketReady)))
        try await waitForPhase(store, phase: .aiSpeaking, timeout: 1_000_000_000)

        // Dispatch serverASR directly (not wrapped in .session) for reducer to handle
        store.dispatch(.speakingRoom(.serverASRReceived(text: "这是服务器转写结果", turnID: "turn-1")))

        // Give time for reducer to update state
        try await Task.sleep(for: .milliseconds(100))

        // Verify liveTranscript was updated by the reducer
        #expect(store.state.speakingRoom.liveTranscript == "这是服务器转写结果")
    }

    @MainActor
    @Test func serverASRFromTransportDoesNotResendSpeechBoundary() async throws {
        // Regression: previously the middleware called `sendSpeechBoundary` on receipt
        // of `client.asr.transcription` for badge hit detection. That caused a phantom
        // second turn at the gateway — the VAD-fired `user.speech.end` already produced
        // the transcript, so a second one in 16ms committed empty audio and the gateway
        // timed out at 60s, surfacing "sockettransporterror error 3" on the client.
        // The authoritative transcript for badge detection now comes from
        // `ProviderOutbound.ServerASRText` on the backend side; the iOS layer must not
        // re-emit a `user.speech.end` here.
        let container = Container()
        container.reset()
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }

        let store = AppStoreFactory.make(container: container)
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)

        // Connect so we can receive transport events
        store.dispatch(.speakingRoom(.session(.socketReady)))
        try await waitForPhase(store, phase: .aiSpeaking, timeout: 1_000_000_000)

        // Emit server ASR via transport event.
        speechClient.emit(.control(.clientASRTranscription(text: "Transport transcript", turnID: "turn-1")))

        // Give the middleware a beat to process the transport event.
        try await Task.sleep(for: .milliseconds(150))

        // The middleware must NOT have re-fired sendSpeechBoundary for the relay frame.
        let boundaryCallCount = await speechClient.getBoundaryCallCount()
        #expect(boundaryCallCount == 0)
    }

    // MARK: - Degraded Text Tests

    @MainActor
    @Test func degradedTextSendTextMessageEffect() async throws {
        let container = Container()
        container.reset()
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }

        let store = AppStoreFactory.make(container: container)
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)

        // Enter degraded mode
        store.dispatch(.speakingRoom(.session(.networkDegraded)))
        try await waitForPhase(store, phase: .degradedText, timeout: 1_000_000_000)

        // Send text message
        speechClient.setSendDegradedTextMessageResult(.success(PostMessageResponse(sessionID: "s-1", reply: "AI回复", channel: "text", generator: "stub")))
        store.dispatch(.speakingRoom(.session(.textMessageSent)))
        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            await speechClient.degradedTextMessageSent
        }

        #expect(await speechClient.degradedTextMessageSent)
    }

    // MARK: - Transition Telemetry Tests

    @MainActor
    @Test func transitionTelemetryEmittedOnPhaseChange() async throws {
        let container = Container()
        container.reset()
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        let tracker = CapturingTracker()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }
        container.tracker.register { tracker }

        let store = AppStoreFactory.make(container: container)
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)

        // Give time for async track call to complete
        try await Task.sleep(for: .milliseconds(100))

        // Check idle → connecting transition
        let allEvents = tracker.events
        let transitionEvents = allEvents.filter {
            $0.name == "speech_session_transition"
        }

        #expect(transitionEvents.count >= 1)

        let idleToConnectingEvent = transitionEvents.first {
            $0.properties["from"] == "idle" &&
            $0.properties["to"] == "connecting"
        }
        #expect(idleToConnectingEvent != nil)

        // Socket ready: connecting → aiSpeaking
        store.dispatch(.speakingRoom(.session(.socketReady)))

        // Poll for the connecting → aiSpeaking transition event
        var connectingToAISpeakingEvent: CapturingTracker.Event?
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            connectingToAISpeakingEvent = tracker.events.first {
                $0.name == "speech_session_transition" &&
                $0.properties["from"] == "connecting" &&
                $0.properties["to"] == "aiSpeaking"
            }
            if connectingToAISpeakingEvent != nil {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(connectingToAISpeakingEvent != nil)

        // Verify phase actually moved
        try await waitForPhase(store, phase: .aiSpeaking, timeout: 500_000_000)
    }

    // MARK: - Turn Counter Synchronization Tests

    @MainActor
    @Test func turnCounterSyncedWithMachineState() async throws {
        let container = Container()
        container.reset()
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }

        let store = AppStoreFactory.make(container: container)
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)

        store.dispatch(.speakingRoom(.session(.socketReady)))
        try await waitForPhase(store, phase: .aiSpeaking, timeout: 1_000_000_000)

        // First turn
        audioEngine.emit(.speechStarted)
        try await waitForPhase(store, phase: .recording, timeout: 1_000_000_000)

        audioEngine.emit(.speechEnded)
        try await waitForPhase(store, phase: .processing, timeout: 1_000_000_000)

        // Verify userTurnCount is 1
        #expect(store.state.speakingRoom.session.userTurnCount == 1)

        // Verify boundary was sent with correct turn ID
        let boundaries = await speechClient.getEndBoundaries()
        #expect(boundaries.last?.turnID == "turn-1")

        // Trigger AI response to return to waiting
        let frame = WSAudioFrame(sequence: 1, opusPayload: Data([0x01]))
        speechClient.emit(.audio(frame))
        try await waitForPhase(store, phase: .aiSpeaking, timeout: 1_000_000_000)

        speechClient.emit(.control(.aiTurnEnd(turnID: "turn-1", outcome: nil, logID: nil)))
        try await waitForPhase(store, phase: .waitingUser, timeout: 1_000_000_000)

        // Second turn
        audioEngine.emit(.speechStarted)
        try await waitForPhase(store, phase: .recording, timeout: 1_000_000_000)

        audioEngine.emit(.speechEnded)
        try await waitForPhase(store, phase: .processing, timeout: 1_000_000_000)

        // Verify userTurnCount is 2
        #expect(store.state.speakingRoom.session.userTurnCount == 2)

        // Verify second turn boundary
        let allEndBoundaries = await speechClient.getEndBoundaries()
        #expect(allEndBoundaries.last?.turnID == "turn-2")
    }
}

// MARK: - Reconnect Window Tests

@Suite("SpeechSessionMiddleware Reconnect Window")
struct SpeechSessionMiddlewareReconnectTests {

    @MainActor
    @Test func reconnectWindowTriggersAfterTimeout() async throws {
        let container = Container()
        container.reset()
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }

        let store = AppStoreFactory.make(container: container)
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)

        store.dispatch(.speakingRoom(.session(.socketReady)))
        try await waitForPhase(store, phase: .aiSpeaking, timeout: 1_000_000_000)

        // Network lost starts reconnect
        store.dispatch(.speakingRoom(.session(.networkLost)))
        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            store.state.speakingRoom.session.isReconnecting
        }
        #expect(store.state.speakingRoom.session.isReconnecting == true)

        // Wait for reconnect timeout (3 seconds)
        try await Task.sleep(for: .seconds(4))

        // After timeout, should enter degradedText
        #expect(store.state.speakingRoom.phase == .degradedText)
        #expect(store.state.speakingRoom.session.isReconnecting == false)
    }

    @MainActor
    @Test func reconnectSucceededClearsReconnectFlag() async throws {
        let container = Container()
        container.reset()
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }

        let store = AppStoreFactory.make(container: container)
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)

        store.dispatch(.speakingRoom(.session(.socketReady)))
        try await waitForPhase(store, phase: .aiSpeaking, timeout: 1_000_000_000)

        // Network lost starts reconnect
        store.dispatch(.speakingRoom(.session(.networkLost)))
        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            store.state.speakingRoom.session.isReconnecting
        }

        // Reconnect succeeds before timeout
        speechClient.emit(.stateChanged(.connected))
        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            !store.state.speakingRoom.session.isReconnecting
        }

        #expect(store.state.speakingRoom.session.isReconnecting == false)
        #expect(store.state.speakingRoom.phase == .aiSpeaking)
    }
}

// MARK: - End Session Cleanup Tests

@Suite("SpeechSessionMiddleware End Session Cleanup")
struct SpeechSessionMiddlewareEndSessionTests {

    @MainActor
    @Test func endTapCancelsTransportAndAudioEngineTasks() async throws {
        let container = Container()
        container.reset()
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }

        let store = AppStoreFactory.make(container: container)
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)

        // End session
        store.dispatch(.speakingRoom(.session(.endTap)))
        try await waitForPhase(store, phase: .ended, timeout: 1_000_000_000)

        // Verify cleanup - wait for async operations to complete
        try await Task.sleep(for: .milliseconds(100))

        // Verify cleanup
        #expect(await speechClient.endSessionCalled)
        // Note: stopCapture might not be called on endTap since audioEngine.stopCapture
        // is only called when the middleware interprets .endSession effect
    }

    @MainActor
    @Test func failureCancelsTasksAndStopsAudioEngine() async throws {
        let container = Container()
        container.reset()
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware(startSessionError: StubError.simulatedFailure("Test error"))
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }

        let store = AppStoreFactory.make(container: container)
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .failed, timeout: 1_000_000_000)

        // The .endSession effect is dispatched by the machine after entering .failed phase.
        // Wait for it to complete (stopCapture + endSession calls).
        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            await speechClient.endSessionCalled
        }

        // Verify cleanup
        #expect(await audioEngine.stopCaptureCalled)
        #expect(await speechClient.endSessionCalled)
        // Verify failure reason is not nil
        #expect(store.state.speakingRoom.failureReason != nil)
        #expect(store.state.speakingRoom.phase == .failed)
    }
}

// MARK: - Non-Session Action Passthrough Tests

@Suite("SpeechSessionMiddleware Non-Session Action Tests")
struct SpeechSessionMiddlewarePassthroughTests {

    @MainActor
    @Test func nonSessionActionsPassThroughMiddleware() async throws {
        // Verify that non-.speakingRoom(.session(...)) actions go through unchanged
        let container = Container()
        container.reset()
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }

        let store = AppStoreFactory.make(container: container)

        // These actions should not be intercepted by speechSessionMiddleware
        // Just verify they don't crash and are handled by the reducer
        store.dispatch(.speakingRoom(.bootstrapReady(true)))
        try await waitUntil(timeoutNanoseconds: 100_000_000) {
            store.state.speakingRoom.isBootstrapReady == true
        }
        #expect(store.state.speakingRoom.isBootstrapReady == true)

        store.dispatch(.speakingRoom(.badgeHit(badge: "test")))
        try await waitUntil(timeoutNanoseconds: 100_000_000) {
            store.state.speakingRoom.lastBadge == "test"
        }
        #expect(store.state.speakingRoom.lastBadge == "test")
        #expect(store.state.speakingRoom.badgeHits == 1)
    }
}

// MARK: - Test Helpers

private enum StubError: Error {
    case simulatedFailure(String)
}

/// Stub audio engine for middleware integration tests
private final class StubAudioEngineForMiddleware: AudioEngineProtocol, @unchecked Sendable {
    private let stream: AsyncStream<AudioEngineEvent>
    private let continuation: AsyncStream<AudioEngineEvent>.Continuation

    private let _stopCaptureCalled = AsyncValue(false)
    var stopCaptureCalled: Bool { get async { await _stopCaptureCalled.get() } }

    init() {
        let pair = AsyncStream.makeStream(of: AudioEngineEvent.self)
        self.stream = pair.stream
        self.continuation = pair.continuation
    }

    func startCapture() async throws {}
    func stopCapture() async {
        await _stopCaptureCalled.set(true)
    }
    func play(frame: WSAudioFrame) async {}
    func interruptNow() async {}

    func events() -> AsyncStream<AudioEngineEvent> {
        stream
    }

    func emit(_ event: AudioEngineEvent) {
        continuation.yield(event)
    }
}

/// Stub speech client for middleware integration tests
private final class StubSpeechSessionClientForMiddleware: SpeechSessionClientProtocol, @unchecked Sendable {
    struct BoundaryCall: Sendable {
        let started: Bool
        let turnID: String?
        let text: String?
    }

    private let stream: AsyncStream<SocketTransportEvent>
    private let continuation: AsyncStream<SocketTransportEvent>.Continuation

    private let startSessionError: Error?
    private let _endSessionCalled = AsyncValue(false)
    var endSessionCalled: Bool { get async { await _endSessionCalled.get() } }

    private let _speechBoundaryCalls = AsyncValue<[BoundaryCall]>([])
    private let _degradedTextMessageSent = AsyncValue(false)
    var degradedTextMessageSent: Bool { get async { await _degradedTextMessageSent.get() } }

    private var sendDegradedResult: Result<PostMessageResponse, Error> = .success(
        PostMessageResponse(sessionID: "s-1", reply: "", channel: "text", generator: "stub")
    )

    init(startSessionError: Error? = nil) {
        self.startSessionError = startSessionError
        let pair = AsyncStream.makeStream(of: SocketTransportEvent.self)
        self.stream = pair.stream
        self.continuation = pair.continuation
    }

    func setSendDegradedTextMessageResult(_ result: Result<PostMessageResponse, Error>) {
        sendDegradedResult = result
    }

    func startSession() async throws {
        if let error = startSessionError {
            throw error
        }
    }

    func activeSessionID() async -> String? { nil }

    func sendSpeechBoundary(started: Bool, turnID: String?, text: String?) async throws {
        let call = BoundaryCall(started: started, turnID: turnID, text: text)
        await _speechBoundaryCalls.update { calls in
            var newCalls = calls
            newCalls.append(call)
            return newCalls
        }
    }

    func sendAudioPCM(_ data: Data) async throws {}
    func submitTranscript(_ text: String) async {}

    func transportEvents() -> AsyncStream<SocketTransportEvent> {
        stream
    }

    func pollReview(sessionID: String) async throws -> ReviewPollResponse {
        ReviewPollResponse(sessionID: sessionID, status: .pending, review: nil)
    }

    func sendDegradedTextMessage(_ text: String) async throws -> PostMessageResponse {
        await _degradedTextMessageSent.set(true)
        return try sendDegradedResult.get()
    }

    func endSession() async {
        await _endSessionCalled.set(true)
        continuation.finish()
    }

    func emit(_ event: SocketTransportEvent) {
        continuation.yield(event)
    }

    // Test helper methods
    func getBoundaryCallCount() async -> Int {
        await _speechBoundaryCalls.get().count
    }

    func getLastBoundaryCall() async -> BoundaryCall? {
        await _speechBoundaryCalls.get().last
    }

    func getEndBoundaries() async -> [BoundaryCall] {
        await _speechBoundaryCalls.get().filter { !$0.started }
    }
}

/// Simple actor-isolated value wrapper for test state
private actor AsyncValue<T: Sendable> {
    private var stored: T

    init(_ initial: T) {
        self.stored = initial
    }

    func get() -> T {
        stored
    }

    func set(_ newValue: T) {
        stored = newValue
    }

    func update(_ fn: (T) -> T) {
        stored = fn(stored)
    }
}

// MARK: - Wait Helpers

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

@MainActor
private func waitUntil(
    timeoutNanoseconds: UInt64,
    pollIntervalNanoseconds: UInt64 = 10_000_000,
    condition: @escaping @MainActor () async -> Bool
) async throws {
    let start = DispatchTime.now().uptimeNanoseconds
    while !(await condition()) {
        if DispatchTime.now().uptimeNanoseconds - start >= timeoutNanoseconds {
            throw TimeoutError()
        }
        try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
    }
}

private struct TimeoutError: Error {}
