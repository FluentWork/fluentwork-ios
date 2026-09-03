import Foundation
import FluentWorkNetworking
import Testing

@Test func controlFrameCodecRoundTripsKnownTypes() throws {
    let frames: [WSControlFrame] = [
        .auth(ticket: "t-1"),
        .sessionReady(sessionID: "s-1", userID: "u-1"),
        .handshake(ticket: "t-1", sessionID: "s-1"),
        .sessionStart(.init(materialContext: "ctx", scene: "interview", voiceID: "v1")),
        .userSpeechStart,
        .userSpeechEnd(text: "thank you", turnID: "turn-1"),
        .aiTextDelta(text: "你好"),
        .aiAudioChunk(sequence: 42),
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
