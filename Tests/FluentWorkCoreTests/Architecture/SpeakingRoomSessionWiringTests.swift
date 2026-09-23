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
    /// Barge-ins the client was asked to send.
    ///
    /// Was `transcripts: [String]`, holding the magic `"__interrupt__"` the
    /// middleware used to pass to `submitTranscript`. Counting the calls is the
    /// same observation with less indirection, and it cannot silently stop
    /// working if a caller passes a different string — there is no string.
    var interruptCalls = 0
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

    func recordInterrupt() {
        interruptCalls += 1
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

    func startSession(continueFromSessionID: String?) async throws {
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

    func sendTurnAbort(turnID: String, outcome: TurnOutcome) async throws {}

    func sendAudioPCM(_ data: Data) async throws {
        if let sendAudioError {
            throw sendAudioError
        }
        await state.recordAudioPayload(data)
    }

    func sendInterrupt() async {
        await state.recordInterrupt()
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

    func closeTransport() async {
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

    func snapshotInterruptCalls() async -> Int {
        await state.interruptCalls
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
    /// 已经解码、走到播放口的 PCM。带轮次归属的帧从 `play(pcm:)` 进来 ——
    /// 「真的出声」这条断言需要它（见 I12 静音事故：sink 收到解码结果才算数）。
    var playedPCM: [Data] = []
    var interruptCalls = 0
    var stopCalls = 0

    func recordStart() {
        startCalls += 1
    }

    func recordPlayedPCM(_ pcm: Data) {
        playedPCM.append(pcm)
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

    func play(pcm: Data) async {
        await state.recordPlayedPCM(pcm)
    }

    func interruptNow() async {
        await state.recordInterrupt()
    }

    func discardActiveSpeech() async {}

    func beginManualSpeech() async {
        emit(.speechStarted)
    }

    func endManualSpeech() async {
        emit(.speechEnded)
    }

    func emit(_ event: AudioEngineEvent) {
        continuation.yield(event)
    }

    func snapshotStartCalls() async -> Int {
        await state.startCalls
    }

    func snapshotPlayedPCM() async -> [Data] {
        await state.playedPCM
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

    func play(pcm: Data) async {}

    func interruptNow() async {}

    func discardActiveSpeech() async {}
}

/// **This test used to assert the opposite**, and the flip is the fix.
///
/// It pinned "entering `.connecting` clears the live transcript, the badge and
/// the timeline" — which is one event doing two jobs: *a session started* and
/// *start over*. Because they were the same event, the only way to begin
/// another session after one ended was to lose the one that had just finished,
/// which is exactly what was reported as 「点击重新开始，前面的内容都没有了」.
///
/// Clearing now belongs to the room entry (`.enterRoom`), which is where the
/// user actually chooses between continuing something and starting fresh.
/// `enterRoomClearsEverythingAFreshRoomShouldNotKeep` is the other half.
@Test func applySessionConnectingKeepsWhatTheUserWasLookingAt() throws {
    let initial = AppState(
        speakingRoom: SpeakingRoomState(
            phase: .processing,
            processingStage: .asr,
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

    store.send(.speakingRoom(.applySession(SpeechSessionState(phase: .connecting))))
    try store.assert(equals: expected)
}

@Test func applySessionConnectingAgainDoesNotClearBadge() throws {
    let initial = AppState(
        speakingRoom: SpeakingRoomState(
            phase: .connecting,
            isBootstrapReady: true,
            lastBadge: "表达自然",
            badgeHits: 1
        )
    )
    let store = TestStore(initialState: initial, reducer: appReducer)
    store.send(.speakingRoom(.applySession(SpeechSessionState(phase: .connecting))))
    try store.assert(equals: initial)
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

    makeSessionLive(store)
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .aiSpeaking
    }
    #expect(store.state.speakingRoom.phase == .aiSpeaking)
}

/// The gate's producer, end to end: the engine's first tapped buffer is what
/// opens the session, and nothing else can stand in for it.
///
/// `makeSessionLive` manufactures the precondition for tests that are about
/// everything *after* the session is live — which means those tests would stay
/// green if the middleware stopped turning `captureFirstBuffer` into
/// `.captureLive`, and the room would go back to opening in front of a silent
/// microphone with a full green suite. This is the test that would go red
/// instead. It is the `102_` failure shape (both sides green, device silent)
/// expressed as an assertion.
@MainActor
@Test func captureFirstBufferOpensTheSession() async {
    let container = Container()
    container.reset()
    let audioEngine = StubAudioEngine()
    container.audioEngine.register { audioEngine }
    container.speechSessionClient.register { StubSpeechSessionClient() }

    let store = AppStoreFactory.make(container: container)
    store.dispatch(.speakingRoom(.session(.sessionStartTap)))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .connecting
    }

    // The socket alone is not enough — this is the half that used to open the
    // session, and it must no longer do so.
    store.dispatch(.speakingRoom(.session(.socketReady)))
    try? await Task.sleep(for: .milliseconds(50))
    #expect(store.state.speakingRoom.phase == .connecting)

    // The tap's first buffer is the half that does.
    audioEngine.emit(.captureFirstBuffer)
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .aiSpeaking
    }
    #expect(store.state.speakingRoom.phase == .aiSpeaking)
}

/// 引擎报一次失败，不得把**进程级**的上行读取者一并带走。
///
/// 引擎的事件流活得比会话长：`LiveAudioEngine` 只在自己的 `deinit` 里
/// `finish()` 那条 continuation（`LiveAudioEngine.swift:447`），`stopCapture()`
/// 不动它。两个泵也由 `OnceFlag` 保证**每进程只起一次**
/// （`SpeechSessionMiddleware.swift:109`，`take()` 只返回一次 true）。所以泵不是
/// 会话资源——这条被两处注释写死：
///
/// - `endSession` 的 handler：`// No .cancel(id: audioEngineEvents): that reader
///   belongs to the engine, not to this session. See audioEventPump.`
///   （`SpeechSessionMiddleware.swift:1328-1329`）
/// - `stopCapture()`：`playbackRetired` 存在的理由之一就是让在途帧
///   `instead of .failed, which would kill the process-lifetime audio pump`
///   （`LiveAudioEngine.swift:743-744`）
///
/// 而 `audioEventPump` 在 `.failed` 上 `return nil`，**正好违反这条**：会话级的
/// 一次失败，终止进程级的读取者。
///
/// 触发它的是日常情形，不是引擎报废。`playbackRetired` 那道工作区只能盖住
/// **`stopCapture()` 之后**到达的播放帧，盖不住这三处：
///
/// - `:723` 路由变化后重装采集 tap 失败（拔插耳机）；
/// - `:834` PCM 长度不是 2 的倍数；
/// - `:1044` 系统中断（`音频被系统中断，本轮练习已停止`）。
///
/// 后果是下一次会话**完全没有上行**：`beginSpeech()` 不跑、`user.speech.start`
/// 不发、一帧 PCM 都不转发、`.captureFirstBuffer` 也没人接。而 `.connecting` 等的
/// 正是后一半（`captureFirstBufferOpensTheSession` 钉的就是这条），于是房间卡在
/// 「连接中」，最后死在 `connectWait` 看门狗上，报的是「连接超时，请重试」。
/// **一次播放/路由故障，换来本次进程内所有后续会话失效，而错误信息指向网络。**
///
/// 三段断言，第一段是必须保持不变的那半：失败仍要被报出来。
@MainActor
@Test func anEngineFailureDoesNotRetireTheUplinkPump() async {
    let container = Container()
    container.reset()
    let audioEngine = StubAudioEngine()
    let speechClient = StubSpeechSessionClient()
    container.audioEngine.register { audioEngine }
    container.speechSessionClient.register { speechClient }

    let store = AppStoreFactory.make(container: container)

    // 会话一：起来、变活。
    store.dispatch(.speakingRoom(.session(.sessionStartTap)))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .connecting
    }
    makeSessionLive(store)
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .aiSpeaking
    }
    #expect(store.state.speakingRoom.phase == .aiSpeaking)

    // 引擎报一次失败。取 `:895` 的原文：一条**每帧**守卫，不是终局宣告。
    audioEngine.emit(.failed("playback engine is not running; dropped frame"))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .failed
    }
    // 这一半必须保持：失败要被报出来。
    #expect(store.state.speakingRoom.phase == .failed)

    // 离开房间（`.failed` 是 `.enterRoom` 允许重置的相位之一），再开一次会话。
    store.dispatch(.speakingRoom(.enterRoom(continueFrom: nil)))
    #expect(store.state.speakingRoom.phase == .idle)
    store.dispatch(.speakingRoom(.session(.sessionStartTap)))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .connecting
    }

    // 会话二的 socket 那一半到位；此时房间**应当**仍停在「连接中」。
    store.dispatch(.speakingRoom(.session(.socketReady)))
    try? await Task.sleep(for: .milliseconds(50))
    #expect(store.state.speakingRoom.phase == .connecting)

    // 另一半只能由泵交付——正是 `captureFirstBufferOpensTheSession` 钉住的那条。
    audioEngine.emit(.captureFirstBuffer)
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .aiSpeaking
    }
    #expect(store.state.speakingRoom.phase == .aiSpeaking)

    // 上行本身：用户开口必须仍然上线。
    audioEngine.emit(.speechStarted)
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        await speechClient.snapshotBoundaries() == [true]
    }
    #expect(await speechClient.snapshotBoundaries() == [true])
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

    speechClient.emit(.control(.aiTTSStart(turnID: "turn-1", voiceID: "mock_voice_01", sampleRate: 16_000, codec: "pcm")))
    let frame = WSAudioFrame(sequence: 7, payload: Data([0x01, 0x02]))
    speechClient.emit(.audio(frame))

    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        await audioEngine.snapshotPlayedPCM().count == 1
    }
    #expect(await audioEngine.snapshotPlayedPCM() == [frame.payload])
}

/// 这条是 2026-09-12 那根保险丝的**接线级**版本。
///
/// 它取代的旧测试叫 `...RoutesTTSFramesToMockDecoderNotAudioEngine`，断言的是
/// 「帧被认领进一台只记录的解码器、不碰音频引擎」—— 那正是事故的形状：网关一发
/// `ai.tts.start`，音频就被认领进录音机，然后现场静音。
///
/// 新契约反过来：**start 认领的帧必须解码成 PCM 到达播放口**。如果将来有人把
/// 解码 seam 换成一个只记录的实现，或者把 keyed 帧又接回旧派发器，这条会红。
@MainActor
@Test func startClaimedTTSFramesReachTheEngineAsSound() async {
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

    // start 之后到达的帧归属这一轮。codec 是 `pcm`（网关发的是重采样后的裸 PCM16）。
    speechClient.emit(
        .control(
            .aiTTSStart(
                turnID: "turn-9",
                voiceID: "mock_voice_01",
                sampleRate: 16_000,
                codec: "pcm"
            )
        )
    )
    let first = WSAudioFrame(sequence: 0, payload: Data([0x0A, 0x0B]))
    let second = WSAudioFrame(sequence: 1, payload: Data([0x0C, 0x0D]))
    speechClient.emit(.audio(first))
    speechClient.emit(.audio(second))
    speechClient.emit(
        .control(.aiTTSEnd(turnID: "turn-9", completionStatus: "ok", durationMs: 40))
    )

    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        await audioEngine.snapshotPlayedPCM().count == 2
    }

    #expect(
        await audioEngine.snapshotPlayedPCM() == [first.payload, second.payload],
        "start 认领的帧必须解码成 PCM 到播放口：停在只记录的组件上就是 2026-09-12 的静音"
    )
}

// 这里曾经有一条 `leftoverTTSStartDoesNotClaimTheNextSessionsFrames`：一场结束后
// 残留的 `ai.tts.start` 不该吞掉下一场的 PCM。它在**接线层测不出来** ——
// stub 的 `endSession()` 会 finish 掉传输流（生产的 socket 同理），所以
// 「会话结束后还有帧到达」只存在于几百微秒的窗口里，断言是碰运气。
//
// 那条不变量现在钉在单元层：`TTSPlaybackCoordinatorTests.resetClearsAttribution`
// （改坏 `reset()` 会让它红，做过变异验证）。会话收尾会调用它这件事本身，
// 是一行代码 + `docs/70_tts_wss_refactor/06` 的记录，不是可观测行为。

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

    makeSessionLive(store)
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
    makeSessionLive(store)
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

    // Drive the machine to `waitingForEvaluation` so a second turn can start.
    speechClient.emit(.control(.aiTTSStart(turnID: "turn-1", voiceID: "mock_voice_01", sampleRate: 16_000, codec: "pcm")))
    let frame = WSAudioFrame(sequence: 1, payload: Data([0x01]))
    speechClient.emit(.audio(frame))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .aiSpeaking
    }
    speechClient.emit(.control(.aiTurnEnd(turnID: "turn-1", outcome: nil, logID: nil)))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.processingStage == .evaluation
    }

    // Second turn → "turn-2". VAD from waitingForEvaluation starts the next recording.
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
    makeSessionLive(store)
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
@Test func restartAfterEndResetsToConnectingAndStartsNewSession() async {
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
    }

    // Host-level restart path: reset snapshot back to idle, then start tap.
    store.dispatch(.speakingRoom(.applySession(.initial)))
    store.dispatch(.speakingRoom(.session(.sessionStartTap)))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        await speechClient.snapshotStartCalls() == 2
            && store.state.speakingRoom.phase == .connecting
    }

    #expect(store.state.speakingRoom.phase == .connecting)
    #expect(await speechClient.snapshotStartCalls() == 2)
}

@MainActor
@Test func transportServerASRUpdatesTimelineListeningRow() async {
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
    makeSessionLive(store)
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .aiSpeaking
    }

    audioEngine.emit(.speechStarted)
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .recording
    }
    audioEngine.emit(.speechEnded)
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.timeline.last?.status == .listening
    }

    speechClient.emit(.control(.clientASRTranscription(
        text: "server transcript",
        turnID: "volc-turn-1"
    )))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.timeline.last?.text == "server transcript"
    }

    #expect(store.state.speakingRoom.timeline.last?.speaker == .user)
    #expect(store.state.speakingRoom.timeline.last?.status == .finalized)
    #expect(store.state.speakingRoom.liveTranscript == "server transcript")
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

    makeSessionLive(store)
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

    speechClient.emit(.control(.aiTTSStart(turnID: "turn-7", voiceID: "mock_voice_01", sampleRate: 16_000, codec: "pcm")))
    let frame = WSAudioFrame(sequence: 7, payload: Data([0x01, 0x02]))
    speechClient.emit(.audio(frame))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .aiSpeaking
    }
    #expect(await audioEngine.snapshotPlayedPCM() == [frame.payload])
    #expect(store.state.speakingRoom.phase == .aiSpeaking)

    speechClient.emit(.control(.aiTurnEnd(turnID: "turn-7", outcome: nil, logID: nil)))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.processingStage == .evaluation
    }
    #expect(store.state.speakingRoom.phase == .processing)
    #expect(store.state.speakingRoom.processingStage == .evaluation)
}

/// The gate's policy, asserted where it is enforced.
///
/// "No PCM leaves the device outside an open utterance" is what keeps the
/// gateway from committing inter-turn audio into the *next* turn's transcript —
/// a measured defect, not a hypothetical: an 83-character transcript came back
/// from a 2.9s tap because the tap runs for the whole session while turns do
/// not.
///
/// It was enforced at exactly one line and **proven nowhere**. The only
/// chunk-level wiring test emitted its chunk *inside* the window, so deleting
/// the guard left the whole suite green — the policy was provable only by
/// reading the code that implemented it. This is the missing half, in both
/// directions: outside is dropped, inside is forwarded, and closing the turn
/// drops again.
@MainActor
@Test func pcmOutsideAnOpenUtteranceNeverReachesTheClient() async {
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
    makeSessionLive(store)
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .aiSpeaking
    }

    // 1. Before any utterance. Capture is already running — it starts with the
    //    session, not with the turn — so this is exactly the audio that used to
    //    be forwarded and committed into whatever came next.
    audioEngine.emit(.pcmChunk(Data([0xDE, 0xAD])))
    try? await Task.sleep(for: .milliseconds(50))
    #expect(await speechClient.snapshotAudioPayloads().isEmpty)

    // 2. Inside an utterance: forwarded, unchanged.
    audioEngine.emit(.speechStarted)
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .recording
    }
    audioEngine.emit(.pcmChunk(Data([0x01, 0x02, 0x03])))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        await speechClient.snapshotAudioPayloads() == [Data([0x01, 0x02, 0x03])]
    }
    #expect(await speechClient.snapshotAudioPayloads() == [Data([0x01, 0x02, 0x03])])

    // 3. After the turn closes: dropped again. This is the regression window —
    //    `user.speech.end` has already been sent, so anything forwarded from
    //    here is transcribed into the next turn.
    audioEngine.emit(.speechEnded)
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .processing
    }
    audioEngine.emit(.pcmChunk(Data([0xBE, 0xEF])))
    try? await Task.sleep(for: .milliseconds(50))
    #expect(await speechClient.snapshotAudioPayloads() == [Data([0x01, 0x02, 0x03])])
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

    makeSessionLive(store)
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .aiSpeaking
    }

    store.dispatch(.speakingRoom(.session(.holdStart)))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        let engineInterrupts = await audioEngine.snapshotInterruptCalls()
        let clientInterrupts = await speechClient.snapshotInterruptCalls()
        return engineInterrupts == 1 && clientInterrupts == 1
    }

    #expect(await audioEngine.snapshotInterruptCalls() == 1)
    #expect(await speechClient.snapshotInterruptCalls() == 1)
}

/// 一次 barge-in 只发**一次** interrupt，而且必须落在 `user.speech.start` 之前。
///
/// 上一条走的是 `holdStart`（直接 dispatch，**不经 pump**），所以它钉住的其实只是
/// **状态机**那一次——VAD 路径的计数一直是空白，这正是本缺陷能活下来的原因。
///
/// 这条走生产路径：`audioEngine.emit(.speechStarted)` → `audioEventPump`。
/// 现状是两次：
///   1. pump 先发一次，在 start **之前**，顺序正确；
///   2. 状态机收到 `.vadSpeechStart` 再发一次。而 `.vadSpeechStart` 是 pump 在
///      `sendSpeechBoundary(started: true)` **之后**才 dispatch 的
///      （`SpeechSessionMiddleware.swift:476-482`），所以第二次**必定**落在
///      `user.speech.start` 之后——把 2026-09-12 修掉的顺序原样退回去
///      （注释原文：「start resets the previous turn's interrupt accounting」）。
@MainActor
@Test func bargeInFromTheVADPathSendsExactlyOneInterrupt() async {
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

    makeSessionLive(store)
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .aiSpeaking
    }

    audioEngine.emit(.speechStarted)
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .recording
    }
    // `.sendInterrupt` 是 fire-and-forget，得给它落地的时间——否则这条测试会在
    // 第二次到达之前就断言，正好把要抓的东西放过去。
    try? await Task.sleep(for: .milliseconds(100))

    #expect(await speechClient.snapshotBoundaries() == [true])
    let interrupts = await speechClient.snapshotInterruptCalls()
    #expect(
        interrupts == 1,
        "一次 barge-in 发了 \(interrupts) 次 interrupt"
    )
}

/// `.waitingUser` 下的打断必须停掉残留音频。
///
/// 这是「徽章早到」那个窗口的兜底：`ai.turn.end` 到达时若 `userTurnCount == 0`
/// （greeting / 首轮），相位落到 `.waitingUser`（`SpeechSessionMachine.swift:75-79`），
/// 而这一轮的全部音频**已经到达客户端、正排在播放器里**——burst 到达只要几十毫秒，
/// 播完要几十秒。此时用户开口，相位 `.waitingUser → .recording`，**改动前不停播**，
/// 残留 TTS 与用户的话叠在一起，正是 `:96-99` 承认的那个形状。
///
/// 这一次 pump 帮不上忙：它的 barge-in 判定是 `phaseBox == .aiSpeaking`，
/// `.waitingUser` 不满足。所以只能由状态机发——而它原先一个 effect 都不发。
@MainActor
@Test func bargeInFromWaitingUserStopsLeftoverPlayback() async {
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

    makeSessionLive(store)
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .aiSpeaking
    }

    // 这一轮的音频已经排进播放器。
    speechClient.emit(
        .control(
            .aiTTSStart(turnID: "turn-1", voiceID: "mock_voice_01", sampleRate: 16_000, codec: "pcm")
        )
    )
    speechClient.emit(.audio(WSAudioFrame(sequence: 1, payload: Data([0x01, 0x02]))))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        await audioEngine.snapshotPlayedPCM().count == 1
    }

    // 轮次结束，但音频还在播。userTurnCount 仍是 0，所以落到 `.waitingUser`。
    speechClient.emit(.control(.aiTurnEnd(turnID: "turn-1", outcome: nil, logID: nil)))
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .waitingUser
    }

    let interruptsBefore = await audioEngine.snapshotInterruptCalls()
    audioEngine.emit(.speechStarted)
    try? await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.speakingRoom.phase == .recording
    }
    // `.stopPlayback` 是 fire-and-forget，给它落地的时间。
    try? await Task.sleep(for: .milliseconds(100))

    #expect(
        await audioEngine.snapshotInterruptCalls() == interruptsBefore + 1,
        "用户从 .waitingUser 开口时没有停掉残留音频"
    )
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
