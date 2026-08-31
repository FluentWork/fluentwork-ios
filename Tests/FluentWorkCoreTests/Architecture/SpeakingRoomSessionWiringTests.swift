import FactoryKit
import Foundation
import Testing
import TGReduxKitTesting
@testable import FluentWorkCore
@testable import FluentWorkNetworking

private actor StubSpeechSessionClientState {
    var startCalls = 0
    var boundaries: [Bool] = []
    var audioPayloads: [Data] = []
    var transcripts: [String] = []
    var endCalls = 0

    func recordStart() {
        startCalls += 1
    }

    func recordBoundary(_ started: Bool) {
        boundaries.append(started)
    }

    func recordAudioPayload(_ data: Data) {
        audioPayloads.append(data)
    }

    func recordTranscript(_ text: String) {
        transcripts.append(text)
    }

    func recordEnd() {
        endCalls += 1
    }
}

private final class StubSpeechSessionClient: SpeechSessionClientProtocol, @unchecked Sendable {
    enum StubError: Error {
        case startFailed
        case sendBoundaryFailed
        case sendAudioFailed
    }

    private let state = StubSpeechSessionClientState()
    private let stream: AsyncStream<SocketTransportEvent>
    private let continuation: AsyncStream<SocketTransportEvent>.Continuation
    private let startSessionError: Error?
    private let boundaryError: Error?
    private let sendAudioError: Error?

    init(
        startSessionError: Error? = nil,
        boundaryError: Error? = nil,
        sendAudioError: Error? = nil
    ) {
        let pair = AsyncStream.makeStream(of: SocketTransportEvent.self)
        self.stream = pair.stream
        self.continuation = pair.continuation
        self.startSessionError = startSessionError
        self.boundaryError = boundaryError
        self.sendAudioError = sendAudioError
    }

    func startSession() async throws {
        if let startSessionError {
            throw startSessionError
        }
        await state.recordStart()
    }

    func sendSpeechBoundary(started: Bool) async throws {
        if let boundaryError {
            throw boundaryError
        }
        await state.recordBoundary(started)
    }

    func sendAudioPCM(_ data: Data) async throws {
        if let sendAudioError {
            throw sendAudioError
        }
        await state.recordAudioPayload(data)
    }

    func submitTranscript(_ text: String) async {
        await state.recordTranscript(text)
    }

    func transportEvents() -> AsyncStream<SocketTransportEvent> {
        stream
    }

    func pollReview(sessionID: String) async throws -> ReviewPollResponse {
        ReviewPollResponse(sessionID: sessionID, status: .pending, review: nil)
    }

    func sendDegradedTextMessage(_ text: String) async throws -> PostMessageResponse {
        PostMessageResponse(sessionID: "s-1", reply: "", channel: "text", generator: "stub")
    }

    func endSession() async {
        await state.recordEnd()
        continuation.finish()
    }

    func snapshotStartCalls() async -> Int {
        await state.startCalls
    }

    func snapshotBoundaries() async -> [Bool] {
        await state.boundaries
    }

    func snapshotAudioPayloads() async -> [Data] {
        await state.audioPayloads
    }

    func snapshotTranscripts() async -> [String] {
        await state.transcripts
    }

    func snapshotEndCalls() async -> Int {
        await state.endCalls
    }

    func emit(_ event: SocketTransportEvent) {
        continuation.yield(event)
    }
}

private actor StubAudioEngineState {
    var startCalls = 0
    var playedFrames: [WSAudioFrame] = []
    var interruptCalls = 0
    var stopCalls = 0

    func recordStart() {
        startCalls += 1
    }

    func recordPlayedFrame(_ frame: WSAudioFrame) {
        playedFrames.append(frame)
    }

    func recordInterrupt() {
        interruptCalls += 1
    }

    func recordStop() {
        stopCalls += 1
    }
}

private final class StubAudioEngine: AudioEngineProtocol, @unchecked Sendable {
    private let stream: AsyncStream<AudioEngineEvent>
    private let continuation: AsyncStream<AudioEngineEvent>.Continuation
    private let state = StubAudioEngineState()

    init() {
        let pair = AsyncStream.makeStream(of: AudioEngineEvent.self)
        self.stream = pair.stream
        self.continuation = pair.continuation
    }

    func startCapture() async throws {
        await state.recordStart()
    }

    func events() -> AsyncStream<AudioEngineEvent> {
        stream
    }

    func stopCapture() async {
        await state.recordStop()
    }

    func play(frame: WSAudioFrame) async {
        await state.recordPlayedFrame(frame)
    }

    func interruptNow() async {
        await state.recordInterrupt()
    }

    func emit(_ event: AudioEngineEvent) {
        continuation.yield(event)
    }

    func snapshotStartCalls() async -> Int {
        await state.startCalls
    }

    func snapshotPlayedFrames() async -> [WSAudioFrame] {
        await state.playedFrames
    }

    func snapshotInterruptCalls() async -> Int {
        await state.interruptCalls
    }

    func snapshotStopCalls() async -> Int {
        await state.stopCalls
    }
}

@Test func applySessionConnectingResetsBadgeAndTranscript() throws {
    let initial = AppState(
        speakingRoom: SpeakingRoomState(
            phase: .processing,
            liveTranscript: "旧转写",
            isBootstrapReady: true,
            lastBadge: "表达自然",
            badgeHits: 2,
            failureReason: "旧错误"
        )
    )
    let store = TestStore(initialState: initial, reducer: appReducer)

    var expected = initial
    expected.speakingRoom.session = SpeechSessionState(phase: .connecting)
    expected.speakingRoom.liveTranscript = ""
    expected.speakingRoom.lastBadge = nil
    expected.speakingRoom.badgeHits = 0

    store.send(.speakingRoom(.applySession(SpeechSessionState(phase: .connecting))))
    try store.assert(equals: expected)
}

@Test func rawSessionEventsDoNotMutateStateInReducer() throws {
    let initial = AppState(
        speakingRoom: SpeakingRoomState(
            phase: .failed,
            isBootstrapReady: true,
            failureReason: "网络错误"
        )
    )
    let store = TestStore(initialState: initial, reducer: appReducer)

    store.send(.speakingRoom(.session(.socketReady)))
    try store.assert(equals: initial)
    store.send(.speakingRoom(.session(.networkDegraded)))
    try store.assert(equals: initial)
}

@MainActor
@Test func speechSessionMiddlewareAppliesMachineOutput() async {
    let container = Container()
    container.reset()
    container.audioEngine.register { StubAudioEngine() }
    container.speechSessionClient.register { StubSpeechSessionClient() }

    let store = AppStoreFactory.make(container: container)
    store.dispatch(.speakingRoom(.session(.sessionStartTap)))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .connecting
    }

    #expect(store.state.speakingRoom.phase == .connecting)

    store.dispatch(.speakingRoom(.session(.socketReady)))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .aiSpeaking
    }
    #expect(store.state.speakingRoom.phase == .aiSpeaking)
}

@MainActor
@Test func speechSessionMiddlewareConsumesTransportBadgeEvents() async {
    let container = Container()
    container.reset()
    let transport = InMemorySocketTransport()
    container.socketTransport.register { transport }

    let store = AppStoreFactory.make(container: container)
    store.dispatch(.speakingRoom(.session(.sessionStartTap)))
    try? await Task.sleep(nanoseconds: 20_000_000)

    await transport.emitControl(.feedbackBadge(badge: "表达自然"))
    try? await Task.sleep(nanoseconds: 20_000_000)

    #expect(store.state.speakingRoom.lastBadge == "表达自然")
    #expect(store.state.speakingRoom.badgeHits == 1)
}

@MainActor
@Test func speechSessionMiddlewareForwardsTransportAudioToAudioEngine() async {
    let container = Container()
    container.reset()
    let audioEngine = StubAudioEngine()
    let speechClient = StubSpeechSessionClient()
    container.audioEngine.register { audioEngine }
    container.speechSessionClient.register { speechClient }

    let store = AppStoreFactory.make(container: container)
    store.dispatch(.speakingRoom(.session(.sessionStartTap)))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        await audioEngine.snapshotStartCalls() == 1
    }

    let frame = WSAudioFrame(sequence: 7, opusPayload: Data([0x01, 0x02]))
    speechClient.emit(.audio(frame))

    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        await audioEngine.snapshotPlayedFrames() == [frame]
    }
    #expect(await audioEngine.snapshotPlayedFrames() == [frame])
}

@MainActor
@Test func speechSessionMiddlewareStartsReconnectWindowOnDisconnect() async {
    let container = Container()
    container.reset()
    let audioEngine = StubAudioEngine()
    let speechClient = StubSpeechSessionClient()
    container.audioEngine.register { audioEngine }
    container.speechSessionClient.register { speechClient }

    let store = AppStoreFactory.make(container: container)
    store.dispatch(.speakingRoom(.session(.sessionStartTap)))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        await speechClient.snapshotStartCalls() == 1
    }

    store.dispatch(.speakingRoom(.session(.socketReady)))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .aiSpeaking
    }

    speechClient.emit(.stateChanged(.disconnected))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.session.isReconnecting
    }

    #expect(store.state.speakingRoom.phase == .aiSpeaking)
    #expect(store.state.speakingRoom.session.isReconnecting)
}

@MainActor
@Test func speechSessionMiddlewareConsumesAudioEngineEvents() async {
    let container = Container()
    container.reset()
    let audioEngine = StubAudioEngine()
    let speechClient = StubSpeechSessionClient()
    container.audioEngine.register { audioEngine }
    container.speechSessionClient.register { speechClient }

    let store = AppStoreFactory.make(container: container)
    store.dispatch(.speakingRoom(.session(.sessionStartTap)))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        let audioStartCalls = await audioEngine.snapshotStartCalls()
        let sessionStartCalls = await speechClient.snapshotStartCalls()
        return audioStartCalls == 1 && sessionStartCalls == 1
    }

    #expect(await audioEngine.snapshotStartCalls() == 1)
    #expect(await speechClient.snapshotStartCalls() == 1)

    store.dispatch(.speakingRoom(.session(.socketReady)))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .aiSpeaking
    }

    audioEngine.emit(.speechStarted)
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .recording
    }
    #expect(store.state.speakingRoom.phase == .recording)
    #expect(await speechClient.snapshotBoundaries() == [true])

    audioEngine.emit(.pcmChunk(Data([0x01, 0x02, 0x03])))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        await speechClient.snapshotAudioPayloads() == [Data([0x01, 0x02, 0x03])]
    }
    #expect(await speechClient.snapshotAudioPayloads() == [Data([0x01, 0x02, 0x03])])

    audioEngine.emit(.speechEnded)
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .processing
    }
    #expect(store.state.speakingRoom.phase == .processing)
    #expect(await speechClient.snapshotBoundaries() == [true, false])

    let frame = WSAudioFrame(sequence: 7, opusPayload: Data([0x01, 0x02]))
    speechClient.emit(.audio(frame))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .aiSpeaking
    }
    #expect(await audioEngine.snapshotPlayedFrames() == [frame])
    #expect(store.state.speakingRoom.phase == .aiSpeaking)

    speechClient.emit(.control(.aiTurnEnd(turnID: "turn-7")))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .waitingUser
    }
    #expect(store.state.speakingRoom.phase == .waitingUser)
}

@MainActor
@Test func speechSessionMiddlewareInterruptsPlaybackImmediately() async {
    let container = Container()
    container.reset()
    let audioEngine = StubAudioEngine()
    let speechClient = StubSpeechSessionClient()
    container.audioEngine.register { audioEngine }
    container.speechSessionClient.register { speechClient }

    let store = AppStoreFactory.make(container: container)
    store.dispatch(.speakingRoom(.session(.sessionStartTap)))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        await speechClient.snapshotStartCalls() == 1
    }

    store.dispatch(.speakingRoom(.session(.socketReady)))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .aiSpeaking
    }

    store.dispatch(.speakingRoom(.session(.holdStart)))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        let interruptCalls = await audioEngine.snapshotInterruptCalls()
        let transcripts = await speechClient.snapshotTranscripts()
        return interruptCalls == 1 && transcripts == ["__interrupt__"]
    }

    #expect(await audioEngine.snapshotInterruptCalls() == 1)
    #expect(await speechClient.snapshotTranscripts() == ["__interrupt__"])
}

@MainActor
@Test func speechSessionMiddlewareCleansUpResourcesOnFailure() async {
    let container = Container()
    container.reset()
    let audioEngine = StubAudioEngine()
    let speechClient = StubSpeechSessionClient(startSessionError: StubSpeechSessionClient.StubError.startFailed)
    container.audioEngine.register { audioEngine }
    container.speechSessionClient.register { speechClient }

    let store = AppStoreFactory.make(container: container)
    store.dispatch(.speakingRoom(.session(.sessionStartTap)))

    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .failed
    }
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        let stopCalls = await audioEngine.snapshotStopCalls()
        let endCalls = await speechClient.snapshotEndCalls()
        return stopCalls == 1 && endCalls == 1
    }

    #expect(store.state.speakingRoom.phase == .failed)
    #expect(await audioEngine.snapshotStopCalls() == 1)
    #expect(await speechClient.snapshotEndCalls() == 1)
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
