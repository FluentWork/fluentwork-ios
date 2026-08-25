import Foundation
import FluentWorkNetworking
import Testing

@Test func controlFrameCodecRoundTripsKnownTypes() throws {
    let frames: [WSControlFrame] = [
        .handshake(ticket: "t-1", sessionID: "s-1"),
        .sessionStart(.init(materialContext: "ctx", scene: "interview", voiceID: "v1")),
        .userSpeechStart,
        .userSpeechEnd,
        .aiTextDelta(text: "你好"),
        .aiAudioChunk(sequence: 42),
        .interrupt,
        .feedbackBadge(badge: "表达自然"),
        .sessionEnd(reason: "completed"),
    ]

    for frame in frames {
        let encoded = try WSControlFrameCodec.encode(frame)
        let decoded = try WSControlFrameCodec.decode(encoded)
        #expect(decoded == frame)
    }
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
    #expect(throws: WSAudioFrameCodecError.truncatedHeader) {
        _ = try WSAudioFrameCodec.decode(Data([0x00, 0x01]))
    }
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
    #expect(mapped == .failed("Network connection lost."))
}

@Test func transportConnectedMapsToSocketReady() {
    let mapped = SocketTransportEventMapper.speakingRoomAction(
        for: .stateChanged(.connected)
    )
    #expect(mapped == .socketReady)
}

@Test func feedbackBadgeMapsToBadgeHit() {
    let mapped = SocketTransportEventMapper.speakingRoomAction(
        for: .control(.feedbackBadge(badge: "表达自然"))
    )
    #expect(mapped == .badgeHit("表达自然"))
}
