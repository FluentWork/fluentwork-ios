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
    // branch on it without resorting to message-string sniffing. Swift's
    // KeyedDecodingContainer surfaces a missing required field as
    // `DecodingError.keyNotFound`, which the Codec propagates unchanged.
    let data = Data(#"{"type":"error","message":"no code here"}"#.utf8)
    #expect(throws: DecodingError.self) {
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
    let frame = WSAudioFrame(sequence: 1_024, opusPayload: Data([0x01, 0x02, 0xFF]))
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

@Test func dropPolicyNeverDropsWithoutInterruptWatermark() {
    #expect(AudioFrameDropPolicy.shouldDrop(frameSequence: 0, interruptMaxSequence: nil) == false)
    #expect(AudioFrameDropPolicy.shouldDrop(frameSequence: 99, interruptMaxSequence: nil) == false)
}

@Test func dropPolicyDropsEqualAndLowerSequences() {
    #expect(AudioFrameDropPolicy.shouldDrop(frameSequence: 10, interruptMaxSequence: 10) == true)
    #expect(AudioFrameDropPolicy.shouldDrop(frameSequence: 9, interruptMaxSequence: 10) == true)
    #expect(AudioFrameDropPolicy.shouldDrop(frameSequence: 11, interruptMaxSequence: 10) == false)
}

@Test func dropGateTracksMaxAndAppliesInclusiveWatermark() {
    var gate = AudioFrameDropGate()
    gate.observe(sequence: 3)
    gate.observe(sequence: 7)
    gate.observe(sequence: 5)
    #expect(gate.maxObservedSequence == 7)

    gate.markInterrupted()
    #expect(gate.shouldDeliver(sequence: 7) == false)
    #expect(gate.shouldDeliver(sequence: 6) == false)
    #expect(gate.shouldDeliver(sequence: 8) == true)
}

/// The gate drops silently, and a silent run of drops is what turns a numbering
/// regression on the gateway side into "the reply is half missing" with nothing
/// in any log to explain it.
@Test func audioDropReportAnnouncesTheRunThenClosesWithTheLoss() {
    var report = AudioDropReport()

    // Opening report: the first drop is what makes a run visible.
    #expect(
        report.recordDrop(sequence: 3, watermark: 240)
            == .audioFrameDropped(sequence: 3, watermark: 240, dropped: 1)
    )
    // Same run, already announced — no repeat for every frame of a 300-frame loss.
    #expect(report.recordDrop(sequence: 4, watermark: 240) == nil)

    // Closing report carries the size of the loss.
    #expect(
        report.closeRun(watermark: 240)
            == .audioFrameDropped(sequence: 0, watermark: 240, dropped: 2)
    )
    #expect(report.closeRun(watermark: 240) == nil)
    #expect(report.dropped == 0)
}

/// A run that never closes is the worst case — the watermark keeps suppressing
/// everything after it — so it must not be the one case that reports nothing.
@Test func audioDropReportKeepsAnUnclosedRunVisible() {
    var report = AudioDropReport()

    _ = report.recordDrop(sequence: 1, watermark: 500)

    #expect(report.dropped == 1)
    #expect(report.reportedWatermark == 500)
}

@Test func audioDropReportResetStartsAFreshRun() {
    var report = AudioDropReport()

    _ = report.recordDrop(sequence: 9, watermark: 240)
    report.reset()

    #expect(report.dropped == 0)
    #expect(report.reportedWatermark == nil)
    #expect(
        report.recordDrop(sequence: 1, watermark: 240)
            == .audioFrameDropped(sequence: 1, watermark: 240, dropped: 1)
    )
}

@Test func inMemoryTransportDropsStaleAudioAfterInterrupt() async {
    let transport = InMemorySocketTransport()
    try? await transport.connect(
        url: URL(string: "ws://127.0.0.1/ws")!,
        sessionID: "s-1",
        ticket: "ticket"
    )

    #expect(await transport.emitAudio(WSAudioFrame(sequence: 1, opusPayload: Data([0x01]))) == true)
    #expect(await transport.emitAudio(WSAudioFrame(sequence: 2, opusPayload: Data([0x02]))) == true)

    await transport.markInterrupted()

    #expect(await transport.emitAudio(WSAudioFrame(sequence: 2, opusPayload: Data([0x02]))) == false)
    #expect(await transport.emitAudio(WSAudioFrame(sequence: 3, opusPayload: Data([0x03]))) == true)
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
        WSAudioFrame(sequence: 1, opusPayload: payload)
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
            .audio(WSAudioFrame(sequence: UInt32(sequence), opusPayload: Data([0x01])))
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

    func markInterrupted() async {
        await transport?.markInterrupted()
    }

    func run(_ source: any SocketMessageSource) async {
        await transport?.receiveLoop(source)
    }

    func release() {
        transport = nil
    }
}

/// The barge-in watermark must not outlive the turn that set it.
///
/// `AudioFrameDropGate.interruptMaxSequence` was cleared only by `connect()`, so
/// within a session it never cleared at all — `clearInterrupt()` had **no
/// production caller**. The thing the gate does is per-turn (drop the audio
/// already in flight when the user barges in); the lifetime it was given is
/// per-session. `77_` P1-7.
///
/// The two only diverge when the sequence numbering goes backwards, which is
/// exactly what F18 was: a transparent reopen restarted numbering at 1 while the
/// watermark sat in the hundreds, and every frame after it was dropped **in
/// silence** — text kept arriving, audio was simply gone. The gateway no longer
/// restarts numbering, but the gate still relies on that. This pins the gate
/// instead of the gateway.
@Test func theBargeInWatermarkDoesNotOutliveItsTurn() async {
    // The holder owns the transport so it can be released before the stream is
    // drained: its `deinit` is what finishes the event stream. Holding a plain
    // reference leaves the loop below waiting on a stream that never ends.
    let (holder, events) = TransportHolder.make()
    let source = InterleavingMessageSource([
        .message(.data(WSAudioFrameCodec.encode(WSAudioFrame(sequence: 1, opusPayload: Data([0x01]))))),
        .message(.data(WSAudioFrameCodec.encode(WSAudioFrame(sequence: 2, opusPayload: Data([0x02]))))),
        // The user barges in: the gate records the highest sequence seen.
        .perform { await holder.markInterrupted() },
        // The interrupted turn ends. Everything it had in flight is now moot,
        // so the watermark has done its job and must go.
        .message(.string(#"{"type":"ai.turn.end","turn_id":"turn-1","outcome":"ok"}"#)),
        // A later frame whose numbering went backwards — the F18 shape. It is
        // a *new* turn's audio and must be delivered, not swallowed by a
        // watermark that belongs to a turn that is over.
        .message(.data(WSAudioFrameCodec.encode(WSAudioFrame(sequence: 1, opusPayload: Data([0x03]))))),
    ])

    await holder.run(source)
    await holder.release()

    var delivered: [UInt32] = []
    for await event in events {
        if case let .audio(frame) = event { delivered.append(frame.sequence) }
    }

    // First turn: 1 and 2 arrive before the barge-in and are played.
    #expect(delivered.contains(1))
    #expect(delivered.contains(2))
    // The last frame shares a sequence with the first, so "delivered twice" is
    // the signature that the watermark was cleared rather than a coincidence.
    #expect(delivered.filter { $0 == 1 }.count == 2, "the post-turn frame was dropped: watermark outlived its turn")
}

/// The test double must report drops the way production does.
///
/// `InMemorySocketTransport` shared the drop **decision** with the real
/// transport but not the drop **report**: production emitted an
/// `audioFrameDropped` diagnostic for every run and the double emitted nothing.
/// So a test could not observe a drop at all — and "is the drop observable" is
/// the first question worth asking when a reply comes back half missing.
///
/// Both now go through ``BargeInAudioGate``, so neither can take the decision
/// without the report. `77_` P1-22.
@Test func inMemoryTransportReportsTheDropsItMakes() async {
    let transport = InMemorySocketTransport()
    try? await transport.connect(
        url: URL(string: "ws://127.0.0.1/ws")!,
        sessionID: "s-1",
        ticket: "ticket"
    )

    #expect(await transport.emitAudio(WSAudioFrame(sequence: 1, opusPayload: Data([0x01]))) == true)
    #expect(await transport.emitAudio(WSAudioFrame(sequence: 2, opusPayload: Data([0x02]))) == true)

    await transport.markInterrupted()

    // Dropped — and, crucially, *said to have been dropped*.
    #expect(await transport.emitAudio(WSAudioFrame(sequence: 2, opusPayload: Data([0x02]))) == false)
    // A later frame closes the run with its size.
    #expect(await transport.emitAudio(WSAudioFrame(sequence: 3, opusPayload: Data([0x03]))) == true)

    // The opening report (the first drop makes the run visible) and the closing
    // one (its size) — the same two the production transport emits.
    let reported = await transport.emittedDiagnostics.compactMap { diagnostic -> Int? in
        guard case let .audioFrameDropped(_, _, dropped) = diagnostic else { return nil }
        return dropped
    }
    #expect(reported == [1, 1], "the double made a drop it never reported: \(reported)")
}
