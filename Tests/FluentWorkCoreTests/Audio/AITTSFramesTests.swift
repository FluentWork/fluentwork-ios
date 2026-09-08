import Foundation
import FluentWorkCore
import FluentWorkNetworking
import Testing

@Test func testAITTSStart_DecodeValid() throws {
    let json = """
    {"type":"ai.tts.start","turn_id":"turn-1","voice_id":"mock_voice_01","sample_rate":24000,"codec":"opus"}
    """
    let decoded = try WSControlFrameCodec.decode(Data(json.utf8))
    #expect(
        decoded == .aiTTSStart(
            turnID: "turn-1",
            voiceID: "mock_voice_01",
            sampleRate: 24_000,
            codec: "opus"
        )
    )
}

@Test func testAITTSAudio_DecodeBinaryFrame() throws {
    let frame = WSAudioFrame(sequence: 0, opusPayload: Data([0x01, 0x02, 0x03]))
    let encoded = WSAudioFrameCodec.encode(frame)
    let decoded = try WSAudioFrameCodec.decode(encoded)
    #expect(decoded == frame)
}

@Test func testAITTSEnd_OptionalDurationMs() throws {
    let withDuration = Data(
        #"{"type":"ai.tts.end","turn_id":"turn-1","completion_status":"ok","duration_ms":200}"#.utf8
    )
    #expect(
        try WSControlFrameCodec.decode(withDuration)
            == .aiTTSEnd(turnID: "turn-1", completionStatus: "ok", durationMs: 200)
    )

    let withoutDuration = Data(
        #"{"type":"ai.tts.end","turn_id":"turn-1","completion_status":"interrupted"}"#.utf8
    )
    #expect(
        try WSControlFrameCodec.decode(withoutDuration)
            == .aiTTSEnd(turnID: "turn-1", completionStatus: "interrupted", durationMs: nil)
    )
}

@Test func testAITTSFrames_TypeConstant() throws {
    let start = try WSControlFrameCodec.encode(
        .aiTTSStart(turnID: "t", voiceID: "v", sampleRate: 24_000, codec: "pcm")
    )
    let end = try WSControlFrameCodec.encode(
        .aiTTSEnd(turnID: "t", completionStatus: "error", durationMs: nil)
    )
    let startJSON = try JSONSerialization.jsonObject(with: start) as? [String: Any]
    let endJSON = try JSONSerialization.jsonObject(with: end) as? [String: Any]
    #expect(startJSON?["type"] as? String == "ai.tts.start")
    #expect(endJSON?["type"] as? String == "ai.tts.end")
}

@Test func testMockDecoder_PrepareFeedFinish_Sequence() throws {
    let decoder = MockTTSDecoder()
    let dispatcher = TTSFrameDispatcher(decoder: decoder)

    try dispatcher.handle(
        control: .aiTTSStart(
            turnID: "turn-1",
            voiceID: "mock_voice_01",
            sampleRate: 24_000,
            codec: "opus"
        )
    )
    try dispatcher.handle(audio: WSAudioFrame(sequence: 0, opusPayload: Data([0x0A])))
    try dispatcher.handle(audio: WSAudioFrame(sequence: 1, opusPayload: Data([0x0B])))
    try dispatcher.handle(
        control: .aiTTSEnd(turnID: "turn-1", completionStatus: "ok", durationMs: 40)
    )

    #expect(decoder.snapshotPrepares().count == 1)
    #expect(decoder.snapshotFeeds().count == 2)
    #expect(decoder.snapshotFinishes().count == 1)
    #expect(decoder.snapshotFeeds().map(\.seq) == [0, 1])
    #expect(decoder.snapshotFeeds().map(\.turnId) == ["turn-1", "turn-1"])
    #expect(decoder.snapshotFinishes()[0].status == "ok")
    #expect(decoder.snapshotFinishes()[0].durationMs == 40)
}

@Test func testMockDecoder_RecordAllCalls() throws {
    let decoder = MockTTSDecoder()

    try decoder.prepare(voiceId: "v-opus", sampleRate: 24_000, codec: "opus")
    try decoder.prepare(voiceId: "v-pcm", sampleRate: 16_000, codec: "pcm")
    try decoder.prepare(voiceId: "v-48", sampleRate: 48_000, codec: "opus")
    try decoder.feed(seq: 3, bytes: Data([0xFF]), turnId: "turn-2")
    try decoder.finish(turnId: "turn-2", status: "error", durationMs: nil)

    #expect(decoder.snapshotPrepares().map(\.codec) == ["opus", "pcm", "opus"])
    #expect(decoder.snapshotPrepares().map(\.sampleRate) == [24_000, 16_000, 48_000])
    #expect(decoder.snapshotFeeds().count == 1)
    #expect(decoder.snapshotFinishes().map(\.status) == ["error"])
}

@Test func testMockDecoder_RejectsUnsupportedCodecAndSampleRate() {
    let decoder = MockTTSDecoder()
    #expect(throws: TTSDecoderError.unsupportedCodec("aac")) {
        try decoder.prepare(voiceId: "v", sampleRate: 24_000, codec: "aac")
    }
    #expect(throws: TTSDecoderError.unsupportedSampleRate(8_000)) {
        try decoder.prepare(voiceId: "v", sampleRate: 8_000, codec: "opus")
    }
}

@Test func testTTSDispatcher_IgnoresAudioBeforeStart() throws {
    let decoder = MockTTSDecoder()
    let dispatcher = TTSFrameDispatcher(decoder: decoder)

    let consumed = try dispatcher.handle(audio: WSAudioFrame(sequence: 0, opusPayload: Data([0x01])))
    #expect(consumed == false)
    #expect(decoder.snapshotFeeds().isEmpty)
}

@Test func testTTSDispatcher_RejectsEmptyPayload() throws {
    let decoder = MockTTSDecoder()
    let dispatcher = TTSFrameDispatcher(decoder: decoder)
    try dispatcher.handle(
        control: .aiTTSStart(
            turnID: "turn-1",
            voiceID: "v",
            sampleRate: 24_000,
            codec: "opus"
        )
    )
    #expect(throws: TTSDecoderError.emptyPayload) {
        try dispatcher.handle(audio: WSAudioFrame(sequence: 0, opusPayload: Data()))
    }
}

@Test func testTTSDispatcher_InterruptDrainsUntilEndWithoutDoubleFinish() throws {
    let decoder = MockTTSDecoder()
    let dispatcher = TTSFrameDispatcher(decoder: decoder)
    try dispatcher.handle(
        control: .aiTTSStart(
            turnID: "turn-1",
            voiceID: "v",
            sampleRate: 24_000,
            codec: "opus"
        )
    )
    try dispatcher.interrupt()
    let leftoverConsumed = try dispatcher.handle(
        audio: WSAudioFrame(sequence: 9, opusPayload: Data([0x99]))
    )
    try dispatcher.handle(
        control: .aiTTSEnd(turnID: "turn-1", completionStatus: "ok", durationMs: 20)
    )

    #expect(leftoverConsumed == true)
    #expect(decoder.snapshotFeeds().isEmpty)
    #expect(decoder.snapshotFinishes().map(\.status) == ["interrupted"])
}

@Test func testTTSDispatcher_ResetClearsActiveStreamSoLegacyPCMCanPlay() throws {
    let decoder = MockTTSDecoder()
    let dispatcher = TTSFrameDispatcher(decoder: decoder)
    try dispatcher.handle(
        control: .aiTTSStart(
            turnID: "turn-1",
            voiceID: "v",
            sampleRate: 24_000,
            codec: "opus"
        )
    )
    try dispatcher.reset()
    let consumed = try dispatcher.handle(audio: WSAudioFrame(sequence: 0, opusPayload: Data([0x01])))

    #expect(consumed == false)
    #expect(decoder.snapshotFinishes().map(\.status) == ["interrupted"])
}

@Test func controlFrameCodecRejectsJSONTTSAudio() throws {
    let data = Data(
        #"{"type":"ai.tts.audio","turn_id":"turn-1","seq":0,"data":"AAEC"}"#.utf8
    )
    #expect(throws: WSControlFrameCodingError.unknownType("ai.tts.audio")) {
        _ = try WSControlFrameCodec.decode(data)
    }
}
