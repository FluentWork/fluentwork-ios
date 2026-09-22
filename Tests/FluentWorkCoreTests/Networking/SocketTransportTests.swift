import Foundation
@testable import FluentWorkNetworking
import Testing

@Test func controlFrameCodecRoundTripsKnownTypes() throws {
    let frames: [WSControlFrame] = [
        .auth(ticket: "t-1"),
        .sessionReady(sessionID: "s-1", userID: "u-1"),
        .handshake(ticket: "t-1", sessionID: "s-1"),
        .sessionStart(.init(materialID: "ctx", sceneType: "interview", voice: "v1")),
        .userSpeechStart,
        .userSpeechEnd(text: "thank you", turnID: "turn-1"),
        .clientTurnAbort(turnID: "turn-1", outcome: .timeout),
        .aiTextDelta(text: "你好", turnID: "turn-1", serverTsMs: 1_728_000_000_000),
        .aiAudioChunk(sequence: 42),
        .aiTTSStart(turnID: "turn-9", voiceID: "mock_voice_01", sampleRate: 24_000, codec: "opus"),
        .aiTTSEnd(turnID: "turn-9", completionStatus: "ok", durationMs: 200),
        .aiTurnEnd(turnID: "turn-42", outcome: nil, logID: nil),
        .interrupt,
        .ping(ts: 1_728_000_000_000),
        .pong(ts: 1_728_000_000_000),
        .feedbackBadge(badge: "表达自然", phraseBlockID: "block-1", tier: .soft, turnID: "turn-1"),
        .sessionEnd(reason: "completed"),
        .error(code: "provider_audio_failed", message: "use of closed network connection"),
        .error(code: "client_asr_required", message: nil),
    ]

    for frame in frames {
        let encoded = try WSControlFrameCodec.encode(frame)
        let decoded = try WSControlFrameCodec.decode(encoded)
        #expect(decoded == frame)
    }
}

@Test func controlFrameCodecDecodesBackendErrorFrame() throws {
    // Mirrors the real backend payload emitted by voicegateway.handler
    // (e.g. provider_audio_failed, provider_control_failed, client_asr_required).
    let data = Data(#"{"type":"error","code":"provider_audio_failed","message":"use of closed network connection"}"#.utf8)
    let decoded = try WSControlFrameCodec.decode(data)
    #expect(decoded == .error(code: "provider_audio_failed", message: "use of closed network connection"))
}

@Test func controlFrameCodecRejectsErrorFrameMissingCode() throws {
    // `code` is the stable machine identifier; it must be required so iOS can
    // branch on it without resorting to message-string sniffing.
    //
    // The error *type* is part of the assertion, and that is the point: a
    // missing required field is this codec's own contract violation, so it
    // says so with its own case. This used to assert `DecodingError.self` — the
    // bare container error, which `URLSessionSocketTransport.describe(_:)`
    // cannot read, so the operator got "The data couldn't be read because it is
    // missing." with no field name in it. The requirement is unchanged (a frame
    // without `code` is rejected); only the failure now has a usable name.
    let data = Data(#"{"type":"error","message":"no code here"}"#.utf8)
    #expect(throws: WSControlFrameCodingError.missingField("code")) {
        _ = try WSControlFrameCodec.decode(data)
    }
}

/// 缺必需字段是**本编解码器自己的契约违规**，就该由它自己的错误类型说出来。
///
/// `WSControlFrameCodingError.missingField` 是为此而声明的，却全仓没有一个
/// `throw`——缺字段抛的是 `KeyedDecodingContainer` 的裸 `DecodingError`。
/// 后果不只是「一个 case 没人用」：`URLSessionSocketTransport.describe(_:)`
/// 只收 `WSControlFrameCodingError`，于是缺字段这条**致命**路径绕开了它，
/// 而那段注释写明它存在的理由正是「让致命解码失败不退化成 NSError 桥接文案」，
/// 并明说 `missingField` 是「必须保住可读信息」的那个 case。
@Test func missingRequiredFieldIsClassifiedAsMissingField() throws {
    // `codec` 是 schema 的 required 之一，这里故意不给。
    let data = Data(
        #"{"type":"ai.tts.start","turn_id":"turn-1","voice_id":"v","sample_rate":16000}"#.utf8
    )
    #expect(throws: WSControlFrameCodingError.missingField("codec")) {
        _ = try WSControlFrameCodec.decode(data)
    }
}

@Test func controlFrameCodecAcceptsErrorFrameWithoutMessage() throws {
    let data = Data(#"{"type":"error","code":"client_asr_required"}"#.utf8)
    let decoded = try WSControlFrameCodec.decode(data)
    #expect(decoded == .error(code: "client_asr_required", message: nil))
}

@Test func controlFrameCodecRejectsUnknownType() throws {
    let data = Data(#"{"type":"unknown.event"}"#.utf8)
    #expect(throws: WSControlFrameCodingError.unknownType("unknown.event")) {
        _ = try WSControlFrameCodec.decode(data)
    }
}

@Test func audioFrameCodecRoundTripsSequenceAndPayload() throws {
    let frame = WSAudioFrame(sequence: 1_024, payload: Data([0x01, 0x02, 0xFF]))
    let encoded = WSAudioFrameCodec.encode(frame)
    #expect(encoded.count == WSAudioFrameCodec.headerByteCount + 3)

    let decoded = try WSAudioFrameCodec.decode(encoded)
    #expect(decoded == frame)
}

@Test func audioFrameCodecRejectsTruncatedHeader() {
    let bytes = Data([0x00, 0x01])
    #expect(throws: WSAudioFrameCodecError.truncatedHeader(byteCount: bytes.count)) {
        _ = try WSAudioFrameCodec.decode(bytes)
    }
}

@Test func audioFrameCodecTruncatedHeaderExposesLocalizedDescription() {
    let error = WSAudioFrameCodecError.truncatedHeader(byteCount: 2)
    let description = (error as LocalizedError).errorDescription
    #expect(description?.contains("2") == true)
    #expect(description?.contains("4") == true)
}

/// The transport has no drop decision of its own.
///
/// It used to run every inbound frame past a barge-in sequence watermark:
/// `AudioFrameDropPolicy`, `AudioFrameDropGate`, `AudioDropReport` and the
/// `BargeInAudioGate` that composed them are all gone — see
/// `18_删除传输层序号水印.md`, and `aBargeInMustNotSwallowTheNextTurnsAudio`
/// below for why a sequence number cannot express turn membership.
///
/// What is left is the transport's actual contract: **every frame it is handed
/// reaches the consumer.** Ascending, repeated and restarted numbering are all
/// in the list, because the transport does not read the value.
@Test func inMemoryTransportDeliversEveryFrameItIsGiven() async {
    let transport = InMemorySocketTransport()
    try? await transport.connect(
        url: URL(string: "ws://127.0.0.1/ws")!,
        sessionID: "s-1",
        ticket: "ticket"
    )

    for sequence: UInt32 in [1, 2, 2, 0, 1] {
        #expect(
            await transport.emitAudio(
                WSAudioFrame(sequence: sequence, payload: Data([UInt8(sequence)]))
            ) == true,
            "the transport dropped frame \(sequence): it has no drop policy to drop it with"
        )
    }
}

@Test func transportFailureMapsToSpeakingRoomFailedAction() {
    let mapped = SocketTransportEventMapper.speakingRoomAction(
        for: .failure(.pingTimedOut)
    )
    #expect(mapped == .networkLost)
}

@Test func transportConnectedMapsToSocketReady() {
    let mapped = SocketTransportEventMapper.speakingRoomAction(
        for: .stateChanged(.connected)
    )
    #expect(mapped == .socketReady)
}

@Test func feedbackBadgeMapsToBadgeHit() {
    let mapped = SocketTransportEventMapper.speakingRoomAction(
        for: .control(.feedbackBadge(
            badge: "表达自然",
            phraseBlockID: "block-1",
            tier: .highlight,
            turnID: "turn-1"
        ))
    )
    #expect(
        mapped == .badgeHit(
            badge: "表达自然",
            phraseBlockID: "block-1",
            tier: .highlight,
            turnID: "turn-1"
        )
    )
}

@Test func transportDisconnectedMapsToNetworkLost() {
    let mapped = SocketTransportEventMapper.speakingRoomAction(
        for: .stateChanged(.disconnected)
    )
    #expect(mapped == .networkLost)
}

/// Plays a fixed script through the receive loop, then ends it the way a
/// cancelled task does — `CancellationError` is the loop's clean exit, so a
/// scripted source can finish without inventing a failure.
private actor ScriptedMessageSource: SocketMessageSource {
    private var remaining: [URLSessionWebSocketTask.Message]
    private let idleBeforeFirst: Duration?
    private var hasIdled = false

    /// `idleBeforeFirst` models the socket sitting with nothing to read — the
    /// normal state of a healthy connection between frames, and the thing a
    /// receive-latency sample must not be measuring.
    init(
        _ messages: [URLSessionWebSocketTask.Message],
        idleBeforeFirst: Duration? = nil
    ) {
        self.remaining = messages
        self.idleBeforeFirst = idleBeforeFirst
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        guard !remaining.isEmpty else { throw CancellationError() }
        if let idleBeforeFirst, !hasIdled {
            hasIdled = true
            try await Task.sleep(for: idleBeforeFirst)
        }
        return remaining.removeFirst()
    }
}

/// Pulls the single `receiveLatency` sample out of a loop run.
private func receiveLatencySample(
    in events: [SocketTransportEvent]
) -> (frameType: String, elapsedMs: Double)? {
    for event in events {
        if case let .diagnostic(.receiveLatency(frameType, _, elapsedMs)) = event {
            return (frameType, elapsedMs)
        }
    }
    return nil
}

/// Pulls the message out of a loop run's decode failure.
///
/// The message is the whole point of a `decodingFailed`: the type alone says
/// "the wire was wrong" without saying which byte. Kept here so a test can
/// assert on the words an operator would actually read.
private func decodingFailureMessage(in events: [SocketTransportEvent]) -> String? {
    for event in events {
        if case let .failure(.decodingFailed(message)) = event { return message }
    }
    return nil
}

/// Drives the receive loop with `source` and returns everything it emitted.
///
/// The transport is scoped so it deinits — that finishes the event stream,
/// which is what lets the loop's output be read without racing it.
private func eventsFromScriptedReceiveLoop(
    _ source: any SocketMessageSource
) async -> [SocketTransportEvent] {
    let stream: AsyncStream<SocketTransportEvent>
    do {
        let transport = URLSessionSocketTransport()
        stream = transport.events
        await transport.receiveLoop(source)
    }

    var collected: [SocketTransportEvent] = []
    for await event in stream { collected.append(event) }
    return collected
}

/// The `frame_type` column must carry the frame's type, not the key `type`.
///
/// The old scan read the text between the first two quotes, which in
/// `{"type":"ping"}` is the key — so every control frame logged the literal
/// `type`, in a column whose stated purpose is to be filtered on.
@Test func controlFrameTypeReadsTheValueNotTheKey() {
    #expect(URLSessionSocketTransport.controlFrameType(in: #"{"type":"ping","ts":7}"#) == "ping")
    #expect(
        URLSessionSocketTransport.controlFrameType(in: #"{"type":"ai.something.new"}"#)
            == "ai.something.new"
    )
    // Spacing must not change the answer.
    #expect(URLSessionSocketTransport.controlFrameType(in: #"{"type" : "pong"}"#) == "pong")

    // No type string at all: `nil` rather than a fabricated name.
    #expect(URLSessionSocketTransport.controlFrameType(in: #"{"ts":7}"#) == nil)
    #expect(URLSessionSocketTransport.controlFrameType(in: "not json") == nil)
}

/// `receiveLatency` must measure the frame, not the wait for it.
///
/// The start sample used to be taken *before* `await receive()`, so the
/// interval was dominated by however long the socket sat with nothing to
/// read — which, on a healthy connection, is nearly all of it. The number
/// still looked plausible, because a burst boundary produces one large sample
/// and everything inside the burst is near zero; nothing about it ever looked
/// wrong, which is why it survived.
@Test func receiveLatencyDoesNotMeasureTheWaitForTheNextFrame() async {
    let events = await eventsFromScriptedReceiveLoop(
        ScriptedMessageSource(
            [.string(#"{"type":"ping","ts":7}"#)],
            idleBeforeFirst: .milliseconds(120)
        )
    )

    let sample = receiveLatencySample(in: events)
    #expect(sample?.frameType == "ping")

    // The run's wall clock is dominated by the 120ms idle by construction, so
    // a sample that includes it reads ~120. Generous headroom for scheduling,
    // still far below the idle it must exclude.
    #expect((sample?.elapsedMs ?? .infinity) < 60)
}

/// The interval has to cover `handle()`, not stop at the decode before it.
///
/// Sampling the end instant before `handle()` measured "receive returned and
/// we parsed a header", while the doc comment on the marker promised
/// "`receive()` returning to `handle()` finishing". Decode and dispatch are
/// exactly the cost this marker exists to expose, so excluding them made it
/// report the one part of the cycle that is never slow.
@Test func receiveLatencyIncludesTheCostOfHandlingTheFrame() async {
    // `WSAudioFrameCodec.decode` copies the payload (`Data(payload)`), so a
    // large frame gives `handle()` a deterministic, measurable cost.
    let payload = Data(count: 8 * 1024 * 1024)
    let encoded = WSAudioFrameCodec.encode(
        WSAudioFrame(sequence: 1, payload: payload)
    )

    let events = await eventsFromScriptedReceiveLoop(
        ScriptedMessageSource([.data(encoded)])
    )

    let sample = receiveLatencySample(in: events)
    #expect(sample?.frameType == "audio_binary")
    // An 8 MiB copy is ~1ms on any modern machine and the idle-inclusive part
    // of a local source is microseconds — so a sample below this floor means
    // handling was measured outside the interval.
    #expect((sample?.elapsedMs ?? 0) > 0.5)
}

/// A gateway that adds a frame type must not be able to disconnect every
/// older client.
///
/// The backend already ignores unknown frame types and counts them. The client
/// threw on one, and the receive loop turned that throw into `.failure` +
/// `.disconnected` + `break` — so shipping a *new* frame type server-side was
/// a fleet-wide disconnect, reported as a decode failure that was really a
/// version difference. This is the same accident class as `unsupported_frame`
/// killing live sessions, relocated to the other end of the wire.
@Test func receiveLoopSurvivesAnUnknownControlFrameType() async {
    let events = await eventsFromScriptedReceiveLoop(
        ScriptedMessageSource([
            .string(#"{"type":"ai.something.new","payload":1}"#),
            .string(#"{"type":"ping","ts":7}"#),
        ])
    )

    // The proof is the *next* frame: it is only delivered if the loop lived.
    #expect(events.contains(.control(.ping(ts: 7))))
    #expect(!events.contains(.stateChanged(.disconnected)))
    #expect(events.contains { if case .failure = $0 { return true } else { return false } } == false)
}

/// Skipping an unknown type must not become skipping *everything*.
///
/// A frame whose envelope is broken is a real contract violation, not a
/// version difference, and must still end the loop — otherwise "be liberal in
/// what you accept" quietly deletes the only signal that the wire is wrong.
@Test func receiveLoopStillDiesOnAMalformedControlFrame() async {
    let events = await eventsFromScriptedReceiveLoop(
        ScriptedMessageSource([
            .string(#"{"type":"ping""#),
        ])
    )

    #expect(events.contains(.stateChanged(.disconnected)))
    #expect(events.contains { if case .failure = $0 { return true } else { return false } })
}

/// 缺必需字段的致命失败，文案里必须点名字段。
///
/// 上一条测试只钉「循环会死」，**从不断言文案**——这正是本缺陷能活到现在的原因。
/// 缺字段抛裸 `DecodingError.keyNotFound`，落到 `handle(message:)` 里 `describe(_:)`
/// 之外的泛化 catch，走 `error.localizedDescription`，也就是 NSError 桥接的
/// "The data couldn't be read because it is missing."——里面没有 `codec` 三个字。
/// 排查一次后端漏填字段，得先猜是哪个字段。
@Test func receiveLoopNamesTheMissingRequiredField() async {
    let events = await eventsFromScriptedReceiveLoop(
        ScriptedMessageSource([
            .string(#"{"type":"ai.tts.start","turn_id":"turn-1","voice_id":"v","sample_rate":16000}"#),
        ])
    )

    let message = decodingFailureMessage(in: events)
    #expect(
        message?.contains("codec") == true,
        "失败文案没点名缺的字段，排查无从下手：\(message ?? "nil")"
    )
}

/// An ignored frame is reported, not swallowed.
///
/// "The server is sending something we ignore" is the first thing worth
/// knowing when a new feature appears to do nothing — and it is indistinguishable
/// from "the server sent nothing" if the skip is silent.
@Test func receiveLoopReportsTheIgnoredFrameType() async {
    let body = #"{"type":"ai.something.new","payload":1}"#
    let events = await eventsFromScriptedReceiveLoop(
        ScriptedMessageSource([.string(body)])
    )

    #expect(
        events.contains(
            .diagnostic(
                .unsupportedControlFrame(type: "ai.something.new", sizeBytes: body.utf8.count)
            )
        )
    )
}

/// The transport must not trade events for a bound.
///
/// A dropped `ai.turn.end` strands the state machine in `processing`; a dropped
/// audio frame leaves a hole in the assistant's speech. The gateway delivers a
/// whole turn's audio in one burst at turn end — around 106 frames for a ten
/// second reply — which is exactly when a 64-event bound starts discarding.
@Test func transportEventStreamDoesNotDropABurst() async {
    let (stream, continuation) = URLSessionSocketTransport.makeEventStream()

    let burst = 200
    for sequence in 0..<burst {
        continuation.yield(
            .audio(WSAudioFrame(sequence: UInt32(sequence), payload: Data([0x01])))
        )
    }
    continuation.finish()

    var received = 0
    for await _ in stream { received += 1 }

    #expect(received == burst)
}

/// A scripted source that can run a side effect between frames — the only way to
/// put a barge-in *in the middle* of an audio stream from a test.
private actor InterleavingMessageSource: SocketMessageSource {
    enum Step: Sendable {
        case message(URLSessionWebSocketTask.Message)
        case perform(@Sendable () async -> Void)
    }

    private var steps: [Step]

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        while !steps.isEmpty {
            switch steps.removeFirst() {
            case let .message(message):
                return message
            case let .perform(action):
                await action()
            }
        }
        throw CancellationError()
    }
}

/// Holds the transport so a `@Sendable` scripted step can reach it, and can
/// drop it again so `deinit` finishes the event stream.
private actor TransportHolder {
    private var transport: URLSessionSocketTransport?

    /// Creates the transport and returns it already owned by the holder.
    ///
    /// **The caller must not keep a reference of its own.** The stream only
    /// finishes when the transport deinits, so a surviving local binding makes
    /// `release()` a no-op and the drain below waits forever. That is not
    /// hypothetical — it is how this test first hung.
    static func make() -> (holder: TransportHolder, events: AsyncStream<SocketTransportEvent>) {
        let transport = URLSessionSocketTransport()
        return (TransportHolder(transport), transport.events)
    }

    private init(_ transport: URLSessionSocketTransport) {
        self.transport = transport
    }

    /// Sends the barge-in the way the app does — as the `control.interrupt`
    /// frame, and nothing else.
    ///
    /// There used to be a second call here, `markInterrupted()`, which armed a
    /// transport-side drop watermark. It is gone: a barge-in on the transport is
    /// now exactly one outbound control frame, and nothing the transport learns
    /// from it can change how it treats inbound audio. That is what the test
    /// below pins.
    ///
    /// This harness never calls `connect()`, so the send itself throws
    /// `notConnected` and is discarded. That is deliberate — what matters is
    /// that the barge-in goes through the real `send(control:)` path, so an
    /// implementation that armed a drop policy from it would be caught.
    func sendInterrupt() async {
        try? await transport?.send(control: .interrupt)
    }

    func run(_ source: any SocketMessageSource) async {
        await transport?.receiveLoop(source)
    }

    func release() {
        transport = nil
    }
}

/// A barge-in must not make the transport swallow the **next** turn's audio.
///
/// The transport used to carry a sequence watermark: the barge-in captured the
/// highest sequence seen so far, and every later frame at or below it was
/// dropped until `ai.turn.end` cleared it. Two things were wrong with that, and
/// they were independent:
///
/// 1. It could not do the job it was written for. The stated purpose was to drop
///    the audio still in flight for the turn the user interrupted — but the
///    WebSocket stream is ordered, so a frame arriving *after* the interrupt
///    necessarily carries a sequence **above** the watermark and was let
///    through. Only duplicates and out-of-order frames could be caught, and
///    neither is what the comment described.
/// 2. It *could* swallow a whole later turn. The gateway's numbering restarts
///    per turn (`08_` §2 measured frames numbered from 0), so while the
///    watermark was armed the next turn's `0..N` were all at or below it.
///
/// `ai.turn.end` releasing the watermark is the only thing that hid (2), and it
/// was a gateway promise rather than a client invariant. A turn that is
/// abandoned — the connection drops, or the server treats the barge-in as a
/// session-level abort — never sends it, and the watermark stayed armed for the
/// rest of the session. That is the script below: the interrupt is never
/// followed by `ai.turn.end`, and the next turn restarts its numbering at 0.
///
/// Every frame must be delivered. Attribution is not the transport's question: a
/// sequence number cannot say which turn a frame belongs to
/// (`07_Stage4_删除死路径.md` §2). `TTSPlaybackCoordinator` answers it on the
/// turn axis, and reports what it drops as `tts_frame_dropped`.
@Test func aBargeInMustNotSwallowTheNextTurnsAudio() async {
    // The holder owns the transport so it can be released before the stream is
    // drained: its `deinit` is what finishes the event stream. Holding a plain
    // reference leaves the loop below waiting on a stream that never ends.
    let (holder, events) = TransportHolder.make()
    let source = InterleavingMessageSource([
        // Turn 1.
        .message(.data(WSAudioFrameCodec.encode(WSAudioFrame(sequence: 1, payload: Data([0x01]))))),
        .message(.data(WSAudioFrameCodec.encode(WSAudioFrame(sequence: 2, payload: Data([0x02]))))),
        // The user barges in. On the transport this is one outbound control
        // frame and nothing else — there is no drop policy left to arm.
        .perform { await holder.sendInterrupt() },
        // Turn 2, numbering restarted from 0. Under the old watermark all three
        // of these were at or below it and were swallowed in silence. No
        // `ai.turn.end` for turn 1, deliberately: the turn was abandoned, so the
        // watermark would never have been released.
        .message(.data(WSAudioFrameCodec.encode(WSAudioFrame(sequence: 0, payload: Data([0x03]))))),
        .message(.data(WSAudioFrameCodec.encode(WSAudioFrame(sequence: 1, payload: Data([0x04]))))),
        .message(.data(WSAudioFrameCodec.encode(WSAudioFrame(sequence: 2, payload: Data([0x05]))))),
    ])

    await holder.run(source)
    await holder.release()

    var delivered: [UInt32] = []
    for await event in events {
        if case let .audio(frame) = event { delivered.append(frame.sequence) }
    }

    // Turn 1 played, then turn 2 — in arrival order, nothing swallowed. The
    // repeated 1 and 2 are the signature: the same sequence value appears in two
    // different turns, and a watermark that decides by sequence cannot tell them
    // apart.
    #expect(
        delivered == [1, 2, 0, 1, 2],
        "the transport dropped audio a barge-in did not make stale: \(delivered)"
    )
}

// The drop **report** that used to be pinned here — `77_` P1-22, "is the drop
// observable when a reply comes back half missing?" — moved with the drop
// *decision* itself, and it moved to the better owner.
//
// The transport no longer drops anything, so there is nothing for it to report.
// The decision is `TTSPlaybackCoordinator.onAudio`'s `.dropped(reason:)`, which
// is tracked as `tts_frame_dropped` / `tts_decoder_failed` in
// `SpeechSessionMiddleware` and carries the datum a sequence watermark never
// had: the `turn_id`, plus a reason (`.superseded` / `.unknownTurn` /
// `.decodeFailed`). See `TTSPlaybackCoordinatorTests.bareFrameBetweenInterruptAndEndIsDropped`
// for the superseded case.
