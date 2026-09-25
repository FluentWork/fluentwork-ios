import Testing
import Foundation
import FluentWorkNetworking
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

    // MARK: - 无 turn_id 处理

    @Test("无 turn_id 的帧被丢弃")
    func frameWithoutTurnIDIsDropped() async {
        let sink = RecordingSink()
        let coordinator = TTSPlaybackCoordinator(decoder: PassthroughAudioFrameDecoder(), sink: sink)

        let outcome = await coordinator.onAudio(TurnKeyedAudioFrame(
            turnID: nil,
            sequence: 0,
            payload: Data([0x01, 0x02])
        ))

        #expect(outcome == .dropped(turnID: nil, reason: .unknownTurn, errorDescription: "frame has no turn_id"))
        #expect(await sink.playCalls.isEmpty)
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

    @Test("未知 turn_id 的帧被丢弃")
    func unknownTurnIDIsDropped() async {
        let sink = RecordingSink()
        let coordinator = TTSPlaybackCoordinator(decoder: PassthroughAudioFrameDecoder(), sink: sink)

        // 未 start 就收到帧（可能是 start 消息丢包）
        let outcome = await coordinator.onAudio(TurnKeyedAudioFrame(
            turnID: "UNKNOWN",
            sequence: 0,
            payload: Data([0x01, 0x02])
        ))

        #expect(outcome == .dropped(turnID: "UNKNOWN", reason: .unknownTurn, errorDescription: "turn_id not registered (missing ai.tts.start)"))
        #expect(await sink.playCalls.isEmpty)
    }
}

// MARK: - 裸帧归属（契约 83：归属由 ai.tts.start / ai.tts.end 括起来决定）

@Suite("裸帧归属与 draining 窗口")
struct TTSPlaybackCoordinatorBareFrameTests {

    @Test("没有 start 时，裸帧被丢弃（必须先有 ai.tts.start）")
    func bareFrameWithoutStartIsDropped() async {
        let sink = RecordingSink()
        let coordinator = TTSPlaybackCoordinator(decoder: PassthroughAudioFrameDecoder(), sink: sink)

        let outcome = await coordinator.onAudioFrame(
            WSAudioFrame(sequence: 0, payload: Data([0x01, 0x02]))
        )

        #expect(outcome == .dropped(turnID: nil, reason: .unknownTurn, errorDescription: "no active turn (missing ai.tts.start)"))
        #expect(await sink.playCalls.isEmpty)
    }

    @Test("start 之后的裸帧归属该轮，经解码后播放")
    func bareFrameAfterStartIsKeyedToThatTurn() async {
        let sink = RecordingSink()
        let coordinator = TTSPlaybackCoordinator(decoder: PassthroughAudioFrameDecoder(), sink: sink)

        await coordinator.onStart(turnID: "T1")
        let outcome = await coordinator.onAudioFrame(
            WSAudioFrame(sequence: 7, payload: Data([0x0A, 0x0B]))
        )

        #expect(outcome == .played(turnID: "T1"))
        #expect(await sink.playCalls.count == 1)
    }

    /// P0-11 在裸帧入口上的形状：打断之后、`ai.tts.end` 之前到达的帧
    /// 仍然属于被打断的那一轮，必须被丢弃。
    @Test("打断之后、end 之前的裸帧被丢弃")
    func bareFrameBetweenInterruptAndEndIsDropped() async {
        let sink = RecordingSink()
        let coordinator = TTSPlaybackCoordinator(decoder: PassthroughAudioFrameDecoder(), sink: sink)

        await coordinator.onStart(turnID: "T1")
        await coordinator.onInterrupt(turnID: "T1")

        let outcome = await coordinator.onAudioFrame(
            WSAudioFrame(sequence: 8, payload: Data([0x08, 0x09]))
        )

        #expect(outcome == .dropped(turnID: "T1", reason: .superseded, errorDescription: nil))
        #expect(await sink.playCalls.isEmpty)
    }

    @Test("end 之后裸帧被丢弃（下一轮需要新的 start）")
    func bareFrameAfterEndIsDropped() async {
        let sink = RecordingSink()
        let coordinator = TTSPlaybackCoordinator(decoder: PassthroughAudioFrameDecoder(), sink: sink)

        await coordinator.onStart(turnID: "T1")
        await coordinator.onEnd(turnID: "T1")

        let outcome = await coordinator.onAudioFrame(
            WSAudioFrame(sequence: 9, payload: Data([0x09, 0x0A]))
        )

        #expect(outcome == .dropped(turnID: nil, reason: .unknownTurn, errorDescription: "no active turn (missing ai.tts.start)"))
        #expect(await sink.playCalls.isEmpty)
    }

    /// 契约 83 §4.3：一轮被打断后可能**永远收不到** `ai.tts.end`（连接断了、回合被
    /// 放弃）。下一个 start 必须结束这个窗口，否则它会把下一轮的音频一起吞掉，
    /// 而唯一的症状是静音。
    @Test("新的 start 结束卡住的 draining 窗口")
    func newStartEndsStuckDrainingWindow() async {
        let sink = RecordingSink()
        let coordinator = TTSPlaybackCoordinator(decoder: PassthroughAudioFrameDecoder(), sink: sink)

        await coordinator.onStart(turnID: "T1")
        await coordinator.onInterrupt(turnID: "T1")
        await coordinator.onStart(turnID: "T2")

        let outcome = await coordinator.onAudioFrame(
            WSAudioFrame(sequence: 12, payload: Data([0x0C, 0x0D]))
        )

        #expect(outcome == .played(turnID: "T2"))
        #expect(await sink.playCalls.count == 1)
    }

    @Test("reset 清空归属，下一场的裸帧被丢弃")
    func resetClearsAttribution() async {
        let sink = RecordingSink()
        let coordinator = TTSPlaybackCoordinator(decoder: PassthroughAudioFrameDecoder(), sink: sink)

        await coordinator.onStart(turnID: "T1")
        await coordinator.reset()

        let outcome = await coordinator.onAudioFrame(
            WSAudioFrame(sequence: 0, payload: Data([0x01, 0x02]))
        )

        #expect(outcome == .dropped(turnID: nil, reason: .unknownTurn, errorDescription: "no active turn (missing ai.tts.start)"))
        #expect(await coordinator.currentTurnID() == nil)
    }

    @Test("没有活跃轮次时打断仍然清空 sink")
    func interruptWithoutATurnStillFlushesSink() async {
        let sink = RecordingSink()
        let coordinator = TTSPlaybackCoordinator(decoder: PassthroughAudioFrameDecoder(), sink: sink)

        await coordinator.onInterrupt(turnID: nil)

        #expect(await sink.interruptCount == 1)
    }

    @Test("空 payload 的裸帧被丢弃并带上原因")
    func emptyPayloadIsDroppedWithReason() async {
        let sink = RecordingSink()
        let coordinator = TTSPlaybackCoordinator(decoder: PassthroughAudioFrameDecoder(), sink: sink)

        await coordinator.onStart(turnID: "T1")
        let outcome = await coordinator.onAudioFrame(WSAudioFrame(sequence: 0, payload: Data()))

        #expect(outcome == .dropped(turnID: "T1", reason: .decodeFailed, errorDescription: "empty payload"))
        #expect(await sink.playCalls.isEmpty)
    }
}

// MARK: - Stage 3：h8 归属表（turn_ref → turn_id）

@Suite("h8 归属表（turn_ref → turn_id）")
struct TTSPlaybackCoordinatorTurnRefTests {

    @Test("带 turn_ref 的帧按归属表解析，不依赖归属指针")
    func turnRefFrameIsResolvedFromTheMap() async {
        let sink = RecordingSink()
        let coordinator = TTSPlaybackCoordinator(decoder: PassthroughAudioFrameDecoder(), sink: sink)

        await coordinator.onStart(turnID: "T1", turnRef: 7)
        let outcome = await coordinator.onAudioFrame(
            WSAudioFrame(sequence: 0, turnRef: 7, payload: Data([0x01, 0x02]))
        )

        #expect(outcome == .played(turnID: "T1"))
        #expect(await sink.playCalls.count == 1)
    }

    @Test("未登记的 turn_ref 被丢弃")
    func unknownTurnRefIsDropped() async {
        let sink = RecordingSink()
        let coordinator = TTSPlaybackCoordinator(decoder: PassthroughAudioFrameDecoder(), sink: sink)

        let outcome = await coordinator.onAudioFrame(
            WSAudioFrame(sequence: 0, turnRef: 99, payload: Data([0x01, 0x02]))
        )

        #expect(
            outcome == .dropped(
                turnID: nil,
                reason: .unknownTurn,
                errorDescription: "turn_ref 99 has no registered turn (missing or closed ai.tts.start)"
            )
        )
        #expect(await sink.playCalls.isEmpty)
    }

    @Test("ai.tts.end 关闭归属表项")
    func endClosesTheMapEntry() async {
        let sink = RecordingSink()
        let coordinator = TTSPlaybackCoordinator(decoder: PassthroughAudioFrameDecoder(), sink: sink)

        await coordinator.onStart(turnID: "T1", turnRef: 7)
        await coordinator.onEnd(turnID: "T1", turnRef: 7)
        let outcome = await coordinator.onAudioFrame(
            WSAudioFrame(sequence: 0, turnRef: 7, payload: Data([0x01, 0x02]))
        )

        #expect(
            outcome == .dropped(
                turnID: nil,
                reason: .unknownTurn,
                errorDescription: "turn_ref 7 has no registered turn (missing or closed ai.tts.start)"
            )
        )
    }

    @Test("下一轮 start 强制关闭上一项（收不到 end 的兜底）")
    func nextStartForceClosesThePreviousEntry() async {
        let sink = RecordingSink()
        let coordinator = TTSPlaybackCoordinator(decoder: PassthroughAudioFrameDecoder(), sink: sink)

        await coordinator.onStart(turnID: "T1", turnRef: 7)
        await coordinator.onStart(turnID: "T2", turnRef: 8)

        let stale = await coordinator.onAudioFrame(
            WSAudioFrame(sequence: 0, turnRef: 7, payload: Data([0x01, 0x02]))
        )
        #expect(
            stale == .dropped(
                turnID: nil,
                reason: .unknownTurn,
                errorDescription: "turn_ref 7 has no registered turn (missing or closed ai.tts.start)"
            )
        )

        let current = await coordinator.onAudioFrame(
            WSAudioFrame(sequence: 0, turnRef: 8, payload: Data([0x03, 0x04]))
        )
        #expect(current == .played(turnID: "T2"))
    }

    @Test("h4 帧（无 turn_ref）仍走归属指针")
    func h4FrameStillUsesThePointer() async {
        let sink = RecordingSink()
        let coordinator = TTSPlaybackCoordinator(decoder: PassthroughAudioFrameDecoder(), sink: sink)

        await coordinator.onStart(turnID: "T1", turnRef: 7)
        let outcome = await coordinator.onAudioFrame(
            WSAudioFrame(sequence: 0, payload: Data([0x01, 0x02]))
        )

        #expect(outcome == .played(turnID: "T1"))
    }

    @Test("reset 清空归属表")
    func resetClearsTheMap() async {
        let sink = RecordingSink()
        let coordinator = TTSPlaybackCoordinator(decoder: PassthroughAudioFrameDecoder(), sink: sink)

        await coordinator.onStart(turnID: "T1", turnRef: 7)
        await coordinator.reset()
        let outcome = await coordinator.onAudioFrame(
            WSAudioFrame(sequence: 0, turnRef: 7, payload: Data([0x01, 0x02]))
        )

        #expect(
            outcome == .dropped(
                turnID: nil,
                reason: .unknownTurn,
                errorDescription: "turn_ref 7 has no registered turn (missing or closed ai.tts.start)"
            )
        )
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
