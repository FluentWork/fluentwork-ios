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
/// | `testTTSDispatcher_IgnoresAudioBeforeStart` | `bareFrameWithoutStartIsDropped`（`TTSPlaybackCoordinatorTests.swift:194`；旧契约本身就是要消灭的 bug） |
/// | `testTTSDispatcher_InterruptDrainsUntilEndWithoutDoubleFinish` | `bareFrameBetweenInterruptAndEndIsDropped` |
/// | `testTTSDispatcher_NewStartEndsAStuckDrainingStream` | `newStartEndsStuckDrainingWindow` |
/// | `testTTSDispatcher_ResetClearsActiveStreamSoLegacyPCMCanPlay` | `resetClearsAttribution`（`leftoverTTSStartDoesNotClaimTheNextSessionsFrames` 已删；`reset` 的意图只剩「残留 start 不吞下一场」那一半，见其原址注释） |
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
            codec: "opus",
            turnRef: nil
        )
    )
}

@Test func testAITTSAudio_DecodeBinaryFrame() throws {
    let frame = WSAudioFrame(sequence: 0, payload: Data([0x01, 0x02, 0x03]))
    let encoded = WSAudioFrameCodec.encode(frame)
    let decoded = try WSAudioFrameCodec.decode(encoded)
    #expect(decoded == frame)
}

/// h4 布局是 4 字节大端 seq + payload，**帧上不带 turn_id**，归属由 start/end
/// 括起来决定。Stage 3 加了可选的 h8（见下），但 **h4 一个字节没改** ——
/// 网关不置 `turn_ref` 时，线上仍然长这样。
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
            == .aiTTSEnd(turnID: "turn-1", completionStatus: "ok", durationMs: 200, turnRef: nil)
    )

    let withoutDuration = Data(
        #"{"type":"ai.tts.end","turn_id":"turn-1","completion_status":"interrupted"}"#.utf8
    )
    #expect(
        try WSControlFrameCodec.decode(withoutDuration)
            == .aiTTSEnd(turnID: "turn-1", completionStatus: "interrupted", durationMs: nil, turnRef: nil)
    )
}

@Test func testAITTSFrames_TypeConstant() throws {
    let start = try WSControlFrameCodec.encode(
        .aiTTSStart(turnID: "t", voiceID: "v", sampleRate: 24_000, codec: "pcm", turnRef: nil)
    )
    let end = try WSControlFrameCodec.encode(
        .aiTTSEnd(turnID: "t", completionStatus: "error", durationMs: nil, turnRef: nil)
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

@Suite("Stage 3：h8 布局与 turn_ref")
struct AITTSAudioH8LayoutTests {

    @Test func h8LayoutIsSequenceThenTurnRefThenPayload() throws {
        let frame = WSAudioFrame(sequence: 0x0102_0304, turnRef: 0x0506_0708, payload: Data([0xAA, 0xBB]))
        let encoded = WSAudioFrameCodec.encode(frame, layout: .h8)

        #expect(
            encoded == Data([
                0x01, 0x02, 0x03, 0x04,
                0x05, 0x06, 0x07, 0x08,
                0xAA, 0xBB,
            ])
        )
        #expect(try WSAudioFrameCodec.decode(encoded, layout: .h8) == frame)
    }

    @Test func h8RejectsAnythingShorterThanEightBytes() {
        let sevenBytes = Data([0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00])
        #expect(throws: WSAudioFrameCodecError.truncatedHeader(byteCount: 7, requiredBytes: 8)) {
            _ = try WSAudioFrameCodec.decode(sevenBytes, layout: .h8)
        }
    }

    /// 读错布局的代价：h8 被当成 h4 读不会抛错，只会把 `turn_ref` 的四个字节
    /// 当成载荷的前两个样本 —— 每帧一次咔哒声，不是静音。这条把那个偏移量钉住，
    /// 它是「布局只能来自信号、不能从长度猜」的理由。
    @Test func h4DecodingOfAnH8FrameShiftsThePayloadByFourBytes() throws {
        let h8 = WSAudioFrameCodec.encode(
            WSAudioFrame(sequence: 9, turnRef: 7, payload: Data([0xAA])),
            layout: .h8
        )
        let misread = try WSAudioFrameCodec.decode(h8, layout: .h4)

        #expect(misread.turnRef == nil)
        #expect(misread.payload == Data([0x00, 0x00, 0x00, 0x07, 0xAA]))
    }

    @Test func aiTTSStartCarriesTurnRefWhenTheGatewaySetsIt() throws {
        let json = #"{"type":"ai.tts.start","turn_id":"t","voice_id":"v","sample_rate":16000,"codec":"pcm","turn_ref":7}"#
        #expect(
            try WSControlFrameCodec.decode(Data(json.utf8))
                == .aiTTSStart(turnID: "t", voiceID: "v", sampleRate: 16_000, codec: "pcm", turnRef: 7)
        )
    }

    @Test func aiTTSStartWithoutTurnRefDecodesAsNil() throws {
        let json = #"{"type":"ai.tts.start","turn_id":"t","voice_id":"v","sample_rate":16000,"codec":"pcm"}"#
        #expect(
            try WSControlFrameCodec.decode(Data(json.utf8))
                == .aiTTSStart(turnID: "t", voiceID: "v", sampleRate: 16_000, codec: "pcm", turnRef: nil)
        )
    }

    @Test func aiTTSEndCarriesTurnRef() throws {
        let json = #"{"type":"ai.tts.end","turn_id":"t","completion_status":"ok","turn_ref":7}"#
        #expect(
            try WSControlFrameCodec.decode(Data(json.utf8))
                == .aiTTSEnd(turnID: "t", completionStatus: "ok", durationMs: nil, turnRef: 7)
        )
    }

    @Test func encodingWithoutTurnRefOmitsTheKey() throws {
        let encoded = try WSControlFrameCodec.encode(
            .aiTTSEnd(turnID: "t", completionStatus: "ok", durationMs: nil, turnRef: nil)
        )
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        #expect(object?["turn_ref"] == nil)
    }
}
