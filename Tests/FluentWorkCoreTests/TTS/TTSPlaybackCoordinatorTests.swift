import Testing
import Foundation
@testable import FluentWorkCore

/// TTSPlaybackCoordinator 的核心测试套件。
///
/// ## 测试策略
///
/// 1. **红测试驱动**：按照 `04_从测试出发.md` §3.3，先写红测试，再实现。
/// 2. **RecordingSink 验证**：所有播放决策通过 `RecordingSink` 记录验证，不依赖真实音频设备。
/// 3. **真实 decoder**：带 `turn_id` 的帧必须经 `AudioFrameDecoder` 解码后到达 sink，
///    避免重演 2026-09-12「start 认领后路由进录音机」的静音事故。
///
/// ## 核心不变量
///
/// - **superseded 轮丢弃**：被打断的轮次的后续帧不播放。
/// - **轮间不交错**：同一时刻只有一个活跃轮次。
/// - **顺序保证**：帧按到达顺序播放（不在此重排）。
/// - **legacy 兼容**：无 turn_id 的帧走旧路径，行为零变化。

@Suite("TTSPlaybackCoordinator 核心逻辑")
struct TTSPlaybackCoordinatorTests {

    // MARK: - 核心不变量：superseded 轮丢弃

    @Test("被打断的轮次的迟到帧不播放")
    func dropsFramesOfSupersededTurn() async {
        let sink = RecordingSink()
        let coordinator = TTSPlaybackCoordinator(decoder: PassthroughAudioFrameDecoder(), sink: sink)

        // 开始轮次 T1
        await coordinator.onStart(turnID: "T1")

        // 播放第一帧
        await coordinator.onAudio(TurnKeyedAudioFrame(
            turnID: "T1",
            sequence: 0,
            payload: Data([0x01, 0x02])
        ))

        // 用户打断
        await coordinator.onInterrupt(turnID: "T1")

        // 迟到的第二帧
        await coordinator.onAudio(TurnKeyedAudioFrame(
            turnID: "T1",
            sequence: 5,
            payload: Data([0x05, 0x06])
        ))

        // 验证：只播放了第一帧，迟到帧被丢弃
        let playCalls = await sink.playCalls
        #expect(playCalls.count == 1, "只应播放第一帧")
        #expect(playCalls[0].pcm == Data([0x01, 0x02]))
    }

    @Test("新轮次启动会立即 supersede 旧轮次")
    func newTurnSupersedesOldTurn() async {
        let sink = RecordingSink()
        let coordinator = TTSPlaybackCoordinator(decoder: PassthroughAudioFrameDecoder(), sink: sink)

        await coordinator.onStart(turnID: "T1")
        await coordinator.onAudio(TurnKeyedAudioFrame(turnID: "T1", sequence: 0, payload: Data([0x01, 0x02])))

        // 开始新轮次（未显式 interrupt，可能是后端直接推送新轮）
        await coordinator.onStart(turnID: "T2")

        // T1 的迟到帧
        await coordinator.onAudio(TurnKeyedAudioFrame(turnID: "T1", sequence: 5, payload: Data([0x05, 0x06])))

        // T2 的正常帧
        await coordinator.onAudio(TurnKeyedAudioFrame(turnID: "T2", sequence: 0, payload: Data([0x10, 0x11])))

        let playCalls = await sink.playCalls
        #expect(playCalls.count == 2, "应该有两次播放：T1 第一帧 + T2 第一帧")
        #expect(playCalls[0].pcm == Data([0x01, 0x02]))
        #expect(playCalls[1].pcm == Data([0x10, 0x11]))
    }

    @Test("onEnd 注销轮次后，该轮次后续帧按未知轮处理")
    func onEndRemovesTurn() async {
        let sink = RecordingSink()
        let coordinator = TTSPlaybackCoordinator(decoder: PassthroughAudioFrameDecoder(), sink: sink)

        await coordinator.onStart(turnID: "T1")
        await coordinator.onEnd(turnID: "T1")

        // onEnd 后 T1 已注销，后续帧成为「未知轮」，默认丢弃
        await coordinator.onAudio(TurnKeyedAudioFrame(turnID: "T1", sequence: 0, payload: Data([0x01, 0x02])))

        #expect(await sink.playCalls.isEmpty)
        #expect(await sink.legacyPlayCalls.isEmpty)
    }

    @Test("onInterrupt 会立即中断 sink")
    func interruptFlushesSink() async {
        let sink = RecordingSink()
        let coordinator = TTSPlaybackCoordinator(decoder: PassthroughAudioFrameDecoder(), sink: sink)

        await coordinator.onStart(turnID: "T1")
        await coordinator.onInterrupt(turnID: "T1")

        #expect(await sink.interruptCount == 1)
    }

    // MARK: - 真实 decoder 保险丝（防止静音事故）

    @Test("start 认领的帧经 decoder 解码后到达 sink（真实解码，非录音机）")
    func startClaimedAudioReachesSinkAsSound() async {
        let sink = RecordingSink()
        let decoder = RecordingAudioFrameDecoder()
        let coordinator = TTSPlaybackCoordinator(decoder: decoder, sink: sink)

        await coordinator.onStart(turnID: "T1")

        // 4 字节 PCM16 数据（2 个样本）
        let pcmData = Data([0x00, 0x01, 0x02, 0x03])
        await coordinator.onAudio(TurnKeyedAudioFrame(turnID: "T1", sequence: 0, payload: pcmData))

        // decoder 被调用：帧没有绕路进「录音机」，而是真走了解码 seam
        let decoded = await decoder.decoded
        #expect(decoded.count == 1, "decoder 应该被调用一次")
        #expect(decoded.first?.payload == pcmData)

        // 解码后的 PCM 到达 sink
        let playCalls = await sink.playCalls
        #expect(playCalls.count == 1, "应该有一次播放调用")
        #expect(playCalls.first?.pcm == pcmData, "播放的数据应该与解码输出一致")
    }

    // MARK: - Legacy 兼容（无 turn_id）

    @Test("无 turn_id 的帧走 legacy 路径")
    func legacyFrameWithoutTurnIDStillPlays() async {
        let sink = RecordingSink()
        let coordinator = TTSPlaybackCoordinator(decoder: PassthroughAudioFrameDecoder(), sink: sink)

        // 过渡期：后端未发 start，直接推二进制帧
        await coordinator.onAudio(TurnKeyedAudioFrame(
            turnID: nil,
            sequence: 0,
            payload: Data([0x01, 0x02])
        ))

        await coordinator.onAudio(TurnKeyedAudioFrame(
            turnID: nil,
            sequence: 1,
            payload: Data([0x03, 0x04])
        ))

        // 验证：legacy 路径仍正常播放
        let legacyCalls = await sink.legacyPlayCalls
        #expect(legacyCalls.count == 2, "应该有两次 legacy 播放")
        #expect(legacyCalls[0].sequence == 0)
        #expect(legacyCalls[1].sequence == 1)
    }

    @Test("有 turn_id 和无 turn_id 的帧不交错")
    func turnKeyedAndLegacyFramesDoNotInterfere() async {
        let sink = RecordingSink()
        let coordinator = TTSPlaybackCoordinator(decoder: PassthroughAudioFrameDecoder(), sink: sink)

        // Legacy 帧
        await coordinator.onAudio(TurnKeyedAudioFrame(turnID: nil, sequence: 0, payload: Data([0x01, 0x02])))

        // 开始有 turn_id 的轮次
        await coordinator.onStart(turnID: "T1")
        await coordinator.onAudio(TurnKeyedAudioFrame(turnID: "T1", sequence: 0, payload: Data([0x10, 0x11])))

        // 又来一个 legacy 帧
        await coordinator.onAudio(TurnKeyedAudioFrame(turnID: nil, sequence: 1, payload: Data([0x02, 0x03])))

        let legacyCount = await sink.legacyPlayCalls.count
        let keyedCount = await sink.playCalls.count
        #expect(legacyCount == 2, "应该有两次 legacy 播放")
        #expect(keyedCount == 1, "应该有一次 keyed 播放")
    }

    // MARK: - 顺序保证

    @Test("同一轮内帧按到达顺序播放")
    func framesWithinTurnPlayInArrivalOrder() async {
        let sink = RecordingSink()
        let coordinator = TTSPlaybackCoordinator(decoder: PassthroughAudioFrameDecoder(), sink: sink)

        await coordinator.onStart(turnID: "T1")

        // 按到达顺序播放（coordinator 不做乱序重排）
        await coordinator.onAudio(TurnKeyedAudioFrame(turnID: "T1", sequence: 0, payload: Data([0x01, 0x02])))
        await coordinator.onAudio(TurnKeyedAudioFrame(turnID: "T1", sequence: 1, payload: Data([0x03, 0x04])))
        await coordinator.onAudio(TurnKeyedAudioFrame(turnID: "T1", sequence: 2, payload: Data([0x05, 0x06])))

        let playCalls = await sink.playCalls
        #expect(playCalls.count == 3)
        #expect(playCalls[0].pcm == Data([0x01, 0x02]))
        #expect(playCalls[1].pcm == Data([0x03, 0x04]))
        #expect(playCalls[2].pcm == Data([0x05, 0x06]))
    }

    // MARK: - 未知 turn_id 处理

    @Test("未知 turn_id 的帧按策略处理")
    func unknownTurnIDHandledByPolicy() async {
        let sink = RecordingSink()
        let coordinator = TTSPlaybackCoordinator(decoder: PassthroughAudioFrameDecoder(), sink: sink)

        // 未 start 就收到帧（可能是 start 消息丢包）
        await coordinator.onAudio(TurnKeyedAudioFrame(
            turnID: "UNKNOWN",
            sequence: 0,
            payload: Data([0x01, 0x02])
        ))

        // 默认策略：丢弃（保守）
        #expect(await sink.playCalls.isEmpty, "未知 turn_id 默认丢弃")
        #expect(await sink.legacyPlayCalls.isEmpty, "未知 turn_id 默认丢弃")
    }

    @Test("未知 turn_id 用 playAsLegacy 策略时透传")
    func unknownTurnWithPlayAsLegacyPolicy() async {
        let sink = RecordingSink()
        let coordinator = TTSPlaybackCoordinator(
            decoder: PassthroughAudioFrameDecoder(),
            sink: sink,
            unknownTurnPolicy: .playAsLegacy
        )

        await coordinator.onAudio(TurnKeyedAudioFrame(
            turnID: "UNKNOWN",
            sequence: 0,
            payload: Data([0x01, 0x02])
        ))

        #expect(await sink.legacyPlayCalls.count == 1)
    }
}

// MARK: - 测试辅助类型

/// 透传解码器：payload 直接作为 PCM16 返回。
private struct PassthroughAudioFrameDecoder: AudioFrameDecoder {
    func decode(_ frame: TurnKeyedAudioFrame) async throws -> Data {
        frame.payload
    }
}

/// 记录解码调用，同时透传 payload。用于验证 coordinator 真的走了解码 seam。
private actor RecordingAudioFrameDecoder: AudioFrameDecoder {
    var decoded: [TurnKeyedAudioFrame] = []

    func decode(_ frame: TurnKeyedAudioFrame) async throws -> Data {
        decoded.append(frame)
        return frame.payload
    }
}
