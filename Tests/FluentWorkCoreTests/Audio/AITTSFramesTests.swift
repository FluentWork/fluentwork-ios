import Foundation
import FluentWorkCore
import FluentWorkNetworking
import Testing

/// `ai.tts.*` 的**线格式**测试。
///
/// ## 这个文件删掉了什么（Stage 4）
///
/// 原先这里还有 9 条 `MockTTSDecoder` / `TTSFrameDispatcher` 的测试。它们钉住的是
/// 旧派发器的状态机（`.idle` 漏帧、`.draining` 认领不播、第二个出口防卡死），
/// 而那个状态机正是要消灭的东西 —— 契约 `meta 83_` §1 说二进制帧格式不变、
/// 归属由 start/end 括起来决定，新实现把「谁在这段区间里」做成显式的查表
/// （`TTSPlaybackCoordinator`），不再是「漏出去还是被接住」。
///
/// 那条状态机里**值得保留的意图**已经迁到对的载体上，逐条对应：
///
/// | 旧测试 | 现在钉在哪 |
/// |--------|-----------|
/// | `testTTSDispatcher_IgnoresAudioBeforeStart` | `bareFrameWithoutStartPlaysAsLegacy`（旧契约本身就是要消灭的 bug） |
/// | `testTTSDispatcher_InterruptDrainsUntilEndWithoutDoubleFinish` | `bareFrameBetweenInterruptAndEndIsDropped` |
/// | `testTTSDispatcher_NewStartEndsAStuckDrainingStream` | `newStartEndsStuckDrainingWindow` |
/// | `testTTSDispatcher_ResetClearsActiveStreamSoLegacyPCMCanPlay` | `resetClearsAttribution` + `leftoverTTSStartDoesNotClaimTheNextSessionsFrames` |
/// | `testTTSDispatcher_RejectsEmptyPayload` | `emptyPayloadIsDroppedWithReason` |
/// | `testMockDecoder_*`（记录 prepare/feed/finish） | 随 Mock 消失；「播了什么」由 `RecordingSink` / `RecordingAudioFrameDecoder` 记录 |
///
/// 时间线一侧由此文件保证：帧怎么编解码、`ai.tts.audio` 为什么不是 JSON 控制帧。

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
    let frame = WSAudioFrame(sequence: 0, payload: Data([0x01, 0x02, 0x03]))
    let encoded = WSAudioFrameCodec.encode(frame)
    let decoded = try WSAudioFrameCodec.decode(encoded)
    #expect(decoded == frame)
}

/// 二进制布局是 4 字节大端 seq + payload，**帧上不带 turn_id**（契约 `83_` §1：
/// 格式一个字节都不改，归属由 start/end 括起来决定）。这条把那个「不带」钉住：
/// 后端如果哪天想塞 turn_id 进帧里，会先在这里红。
@Test func testAITTSAudio_BinaryLayoutIsSequenceThenPayload() throws {
    let encoded = WSAudioFrameCodec.encode(
        WSAudioFrame(sequence: 0x0102_0304, payload: Data([0xAA, 0xBB]))
    )
    #expect(encoded == Data([0x01, 0x02, 0x03, 0x04, 0xAA, 0xBB]))
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

@Test func controlFrameCodecRejectsJSONTTSAudio() throws {
    let data = Data(
        #"{"type":"ai.tts.audio","turn_id":"turn-1","seq":0,"data":"AAEC"}"#.utf8
    )
    #expect(throws: WSControlFrameCodingError.unknownType("ai.tts.audio")) {
        _ = try WSControlFrameCodec.decode(data)
    }
}
