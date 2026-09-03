import FactoryKit
import FluentWorkDiagnostics
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
    var boundaryTurnIDs: [String?] = []
    var sessionID: String?

    func recordStart() {
        startCalls += 1
    }

    func recordBoundary(_ started: Bool, turnID: String?) {
        boundaries.append(started)
        boundaryTurnIDs.append(turnID)
    }

    func recordSessionID(_ sessionID: String?) {
        self.sessionID = sessionID
    }

    func recordAudioPayload(_ data: Data) {
        audioPayloads.append(data)
    }

    func recordTranscript(_ text: String) {
        transcripts.append(text)
    }

    func recordEnd() {
        endCalls += 1
        sessionID = nil
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
        await state.recordSessionID("s-1")
    }

    func activeSessionID() async -> String? {
        await state.sessionID
    }

    func sendSpeechBoundary(started: Bool, turnID: String?, text: String?) async throws {
        if let boundaryError {
            throw boundaryError
        }
        await state.recordBoundary(started, turnID: turnID)
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

    func snapshotBoundaryTurnIDs() async -> [String?] {
        await state.boundaryTurnIDs
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

private final class FailingPermissionAudioEngine: AudioEngineProtocol, @unchecked Sendable {
    func startCapture() async throws {
        throw AudioEnginePermissionError.microphoneDenied
    }

    func events() -> AsyncStream<AudioEngineEvent> {
        AsyncStream { _ in }
    }

    func stopCapture() async {}

    func play(frame: WSAudioFrame) async {}

    func interruptNow() async {}
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
    let audioEngine = StubAudioEngine()
    let speechClient = StubSpeechSessionClient()
    container.audioEngine.register { audioEngine }
    container.speechSessionClient.register { speechClient }

    let store = AppStoreFactory.make(container: container)
    store.dispatch(.speakingRoom(.session(.sessionStartTap)))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        await speechClient.snapshotStartCalls() == 1
    }

    speechClient.emit(.control(.feedbackBadge(
        badge: "表达自然",
        phraseBlockID: "block-1",
        tier: .soft,
        turnID: "turn-1"
    )))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.lastBadge == "表达自然"
    }

    #expect(store.state.speakingRoom.lastBadge == "表达自然")
    #expect(store.state.speakingRoom.badgeHits == 1)
    #expect(store.state.badgeFeedback.entries.first?.phraseBlockID == "block-1")
    #expect(store.state.badgeFeedback.entries.first?.tier == .badgeOnly) // soft → badgeOnly
    #expect(store.state.badgeFeedback.entries.first?.turnID == "turn-1")
}

@MainActor
@Test func backendFeedbackBadgeJSONDecodesIntoStoreEntries() async throws {
    // Closes the wire-to-store gap without standing up a WSS server: the JSON
    // literal is the exact frame shape `handler_dev_echo_test.go` proves the
    // backend BadgeEmitter writes over a live connection (including the
    // backend-only correlation fields `session_id` / `dedupe_key`).
    let backendFrameJSON = Data(#"""
    {
      "type": "feedback.badge",
      "badge": "Let's ship it.",
      "phrase_block_id": "block-ship-it",
      "tier": "soft",
      "session_id": "s1",
      "turn_id": "turn-e2e-1",
      "dedupe_key": "s1|turn-e2e-1|block-ship-it"
    }
    """#.utf8)

    let frame = try WSControlFrameCodec.decode(backendFrameJSON)
    guard case let .feedbackBadge(badge, phraseBlockID, tier, turnID) = frame else {
        Issue.record("expected feedback.badge frame, got \(frame)")
        return
    }
    #expect(badge == "Let's ship it.")
    #expect(phraseBlockID == "block-ship-it")
    #expect(tier == .soft)
    #expect(turnID == "turn-e2e-1")

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

    speechClient.emit(.control(frame))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.lastBadge == "Let's ship it."
    }

    #expect(store.state.speakingRoom.lastBadge == "Let's ship it.")
    #expect(store.state.speakingRoom.badgeHits == 1)
    #expect(store.state.badgeFeedback.entries.count == 1)
    #expect(store.state.badgeFeedback.entries.first?.badge == "Let's ship it.")
    #expect(store.state.badgeFeedback.entries.first?.phraseBlockID == "block-ship-it")
    #expect(store.state.badgeFeedback.entries.first?.tier == .badgeOnly) // soft → badgeOnly
    #expect(store.state.badgeFeedback.entries.first?.turnID == "turn-e2e-1")
}

@MainActor
@Test func backendPreB12FeedbackBadgeJSONLandsWithUnknownTier() async throws {
    // Runbook §6.1: pre-B12 backend versions omit `tier`. The frame must
    // survive decode + transport + reducer and display as `.unknown` while
    // still carrying the phrase block and turn for dedupe.
    let preB12FrameJSON = Data(#"""
    {
      "type": "feedback.badge",
      "badge": "表达自然",
      "phrase_block_id": "block-old",
      "turn_id": "turn-old"
    }
    """#.utf8)

    let frame = try WSControlFrameCodec.decode(preB12FrameJSON)

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

    speechClient.emit(.control(frame))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.lastBadge == "表达自然"
    }

    #expect(store.state.badgeFeedback.entries.count == 1)
    #expect(store.state.badgeFeedback.entries.first?.badge == "表达自然")
    #expect(store.state.badgeFeedback.entries.first?.phraseBlockID == "block-old")
    #expect(store.state.badgeFeedback.entries.first?.tier == .unknown)
    #expect(store.state.badgeFeedback.entries.first?.turnID == "turn-old")
}

@MainActor
@Test func speechSessionMiddlewareSurfacesMicrophoneDeniedMessage() async {
    let container = Container()
    container.reset()
    let audioEngine = FailingPermissionAudioEngine()
    let speechClient = StubSpeechSessionClient()
    container.audioEngine.register { audioEngine }
    container.speechSessionClient.register { speechClient }

    let store = AppStoreFactory.make(container: container)
    store.dispatch(.speakingRoom(.session(.sessionStartTap)))

    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .failed
    }

    #expect(store.state.speakingRoom.phase == .failed)
    #expect(store.state.speakingRoom.failureReason == "无法访问麦克风，请在系统设置中允许 FluentWork 使用麦克风。")
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
@Test func speechSessionMiddlewareForwardsTurnIDToSpeechBoundary() async {
    let container = Container()
    container.reset()
    let audioEngine = StubAudioEngine()
    let speechClient = StubSpeechSessionClient()
    container.audioEngine.register { audioEngine }
    container.speechSessionClient.register { speechClient }

    let store = AppStoreFactory.make(container: container)
    store.dispatch(.speakingRoom(.session(.sessionStartTap)))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .connecting
    }
    store.dispatch(.speakingRoom(.session(.socketReady)))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .aiSpeaking
    }

    // First turn: VAD start/stop → boundary should carry "turn-1".
    audioEngine.emit(.speechStarted)
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .recording
    }
    audioEngine.emit(.speechEnded)
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        await speechClient.snapshotBoundaries() == [true, false]
    }
    let turnIDsAfterFirst = await speechClient.snapshotBoundaryTurnIDs()
    #expect(turnIDsAfterFirst == [nil, "turn-1"])
    #expect(store.state.speakingRoom.session.userTurnCount == 1)

    // Drive the machine back to `waitingUser` so a second turn can start.
    let frame = WSAudioFrame(sequence: 1, opusPayload: Data([0x01]))
    speechClient.emit(.audio(frame))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .aiSpeaking
    }
    speechClient.emit(.control(.aiTurnEnd(turnID: "turn-1")))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .waitingUser
    }

    // Second turn → "turn-2".
    audioEngine.emit(.speechStarted)
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .recording
    }
    audioEngine.emit(.speechEnded)
    // Wait for the userTurnCount increment to land — boundary count races
    // with the dispatch of `.vadSpeechEnd(turnID:)` in the audio loop.
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.session.userTurnCount == 2
    }
    #expect(await speechClient.snapshotBoundaries() == [true, false, true, false])
    let turnIDsAfterSecond = await speechClient.snapshotBoundaryTurnIDs()
    #expect(turnIDsAfterSecond == [nil, "turn-1", nil, "turn-2"])
}

@MainActor
@Test func speechSessionMiddlewareEmitsSchemaAlignedTurnEndedEvent() async {
    let container = Container()
    container.reset()
    let audioEngine = StubAudioEngine()
    let speechClient = StubSpeechSessionClient()
    let tracker = CapturingTracker()
    container.audioEngine.register { audioEngine }
    container.speechSessionClient.register { speechClient }
    container.tracker.register { tracker }

    let store = AppStoreFactory.make(container: container)
    store.dispatch(.speakingRoom(.session(.sessionStartTap)))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .connecting
    }
    store.dispatch(.speakingRoom(.session(.socketReady)))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .aiSpeaking
    }

    audioEngine.emit(.speechStarted)
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .recording
    }
    audioEngine.emit(.speechEnded)
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.session.userTurnCount == 1
    }

    // The schema-aligned observability event should carry the same
    // `turn_id` the boundary frame sent, plus `source=ios` so backend
    // and iOS can correlate one turn end-to-end.
    let events = tracker.events
    let turnEnded = events.first(where: { $0.name == "speech_turn_ended" })
    #expect(turnEnded?.properties["turn_id"] == "turn-1")
    #expect(turnEnded?.properties["source"] == "ios")
    #expect(turnEnded?.properties["stage"] == "turn_boundary")
}

@MainActor
@Test func endingSessionCapturesSessionIDForReviewNavigation() async {
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

    store.dispatch(.speakingRoom(.session(.endTap)))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .ended
            && store.state.speakingRoom.lastSessionID == "s-1"
    }

    #expect(store.state.speakingRoom.phase == .ended)
    #expect(store.state.speakingRoom.lastSessionID == "s-1")
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
