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
}

private final class StubSpeechSessionClient: SpeechSessionClientProtocol, @unchecked Sendable {
    private let state = StubSpeechSessionClientState()
    private let stream: AsyncStream<SocketTransportEvent>
    private let continuation: AsyncStream<SocketTransportEvent>.Continuation

    init() {
        let pair = AsyncStream.makeStream(of: SocketTransportEvent.self)
        self.stream = pair.stream
        self.continuation = pair.continuation
    }

    func startSession() async throws {
        await state.recordStart()
    }

    func sendSpeechBoundary(started: Bool) async throws {
        await state.recordBoundary(started)
    }

    func sendAudioPCM(_ data: Data) async throws {
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

    func endSession() async {}

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

    func emit(_ event: SocketTransportEvent) {
        continuation.yield(event)
    }
}

private actor StubAudioEngineState {
    var startCalls = 0
    var playedFrames: [WSAudioFrame] = []
    var interruptCalls = 0

    func recordStart() {
        startCalls += 1
    }

    func recordPlayedFrame(_ frame: WSAudioFrame) {
        playedFrames.append(frame)
    }

    func recordInterrupt() {
        interruptCalls += 1
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

    func stopCapture() async {}

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
