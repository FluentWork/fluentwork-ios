import Foundation
import FluentWorkNetworking

/// 一帧下行音频的处理结果。
public enum TTSFrameOutcome: Equatable, Sendable {
    /// 归属某一轮，已经过解码并交给 sink
    case played(turnID: String)
    /// 丢弃。`errorDescription` 在解码失败时非空
    case dropped(turnID: String?, reason: TTSDropReason, errorDescription: String?)
}

public enum TTSDropReason: String, Equatable, Sendable {
    /// 这一轮已被打断或已被新轮取代（旧的 `.draining` 窗口）
    case superseded
    /// 有 turn_id，但注册表里没有对应的 start（start 丢了、乱序，或已被 end 注销）
    case unknownTurn
    /// 解码 seam 抛错，或 payload 为空
    case decodeFailed
}

/// TTS 播放协调器：基于 `turn_id` 路由下行音频帧，支持打断。
///
/// ## 设计目标
///
/// 1. **修复串音 bug**：用户打断后，前一轮的残留帧不再播放（P0-11 根因）。
/// 2. **强制 turn_id**：所有帧必须有 turn_id，无 ai.tts.start 则无声音。
/// 3. **可测试决策**：通过 `RecordingSink` 验证播/丢逻辑，不依赖真实音频设备。
/// 4. **真实解码**：所有帧经 `AudioFrameDecoder` 解码成 PCM 后播放。
///
/// ## 轮次归属（契约 `meta 83_`）
///
/// **二进制帧格式不变**：4 字节大端 seq + payload，帧上不带 `turn_id`。归属由
/// 「谁是这段 `ai.tts.start` / `ai.tts.end` 之间的帧」决定。所以裸帧入口
/// （`onAudioFrame`）按**当前归属指针**解析轮次。
///
/// ## 三个状态，一张注册表
///
/// - 归属指针 `attributionTurnID`：最近的 `ai.tts.start`。`ai.tts.end` 才清空。
/// - 注册表 `turnRegistry`：`turn_id → .active | .superseded`。
/// - 裸帧路由：指针非空 → 按注册表判定；指针为空 → **丢弃**。
///
/// **打断不移动归属指针。** 打断之后、`ai.tts.end` 之前，线上仍在到达的帧
/// 依然属于被打断的那一轮，必须被丢弃。若在打断时把指针清空，它们会被判为
/// 「未知轮」而丢弃，但 errorDescription 会说「missing ai.tts.start」而不是
/// 「superseded」，这会误导诊断。指针的移动只发生在 start 与 end。
public actor TTSPlaybackCoordinator {
    /// 轮次状态
    private enum TurnState: Sendable, Equatable {
        case active
        case superseded
    }

    /// 轮次注册表：turn_id → state
    ///
    /// `.superseded` 的条目**保留到 `onEnd`**，不提前清理：被取代轮的迟到帧必须
    /// 判成「已作废」而不是「未知轮」。两者的默认结局都是丢弃，但
    /// `unknownTurnPolicy == .playAsLegacy` 时未知轮会被**播出去** —— 提前清理
    /// 注册表等于给串音开一条后门，而它只在非默认策略下出现。
    private var turnRegistry: [String: TurnState] = [:]

    /// 归属指针：线上帧属于哪一轮。`ai.tts.start` 设置，`ai.tts.end` / `reset` 清空。
    private var attributionTurnID: String?

    /// 唯一解码 seam：payload → 16k mono PCM16
    private let decoder: any AudioFrameDecoder

    /// 音频播放 sink
    private let sink: any AudioSink

    public init(
        decoder: any AudioFrameDecoder,
        sink: any AudioSink
    ) {
        self.decoder = decoder
        self.sink = sink
    }

    // MARK: - Turn Lifecycle

    /// 开始新轮次（`ai.tts.start`）。
    ///
    /// - 自动 supersede 前一个活跃轮次（即使未显式 interrupt）
    /// - 注册新 turn_id 为 `.active`，并把归属指针移到它
    ///
    /// 自动 supersede 也是那个「卡住的窗口」的第二个出口：一轮被打断后如果
    /// **永远收不到** `ai.tts.end`（连接断了、回合被放弃），旧的 draining 状态会
    /// 把下一轮的音频一起吞掉，而唯一的症状是静音。
    public func onStart(turnID: String) async {
        if let previousTurn = attributionTurnID {
            turnRegistry[previousTurn] = .superseded
        }
        turnRegistry[turnID] = .active
        attributionTurnID = turnID
    }

    /// 打断（barge-in）。
    ///
    /// - 把指定轮次标记为 `.superseded`，它之后的帧只丢弃
    /// - 立即中断 sink 的 in-flight 缓冲（已经排进播放器的那些）
    /// - **不动归属指针**（见类型注释）
    ///
    /// `turnID` 可空：没有已知轮次时（今天全是 legacy 帧）打断仍要清空播放器。
    public func onInterrupt(turnID: String?) async {
        if let turnID {
            turnRegistry[turnID] = .superseded
        }
        await sink.interruptNow()
    }

    /// 结束轮次（`ai.tts.end`）：注销 turn_id，并在它是当前轮时清空归属指针。
    public func onEnd(turnID: String) async {
        turnRegistry[turnID] = nil
        if attributionTurnID == turnID {
            attributionTurnID = nil
        }
    }

    /// 清空全部轮次与归属。会话收尾时调用，让残留的 `ai.tts.start` 无法吞掉
    /// 下一场的 legacy PCM。
    public func reset() async {
        turnRegistry.removeAll()
        attributionTurnID = nil
    }

    /// 当前归属指针。供埋点使用（`tts_first_audio` / `tts_interrupt` 的 turn_id）。
    public func currentTurnID() -> String? {
        attributionTurnID
    }

    // MARK: - Audio Frame Routing

    /// 裸帧入口：线上二进制帧（只有 seq + payload）从这里进来。
    ///
    /// 归属由归属指针解析 —— 必须有活跃轮次，否则丢弃。
    /// 移除了 legacy 路径：所有帧必须经过 ai.tts.start 认领。
    public func onAudioFrame(_ frame: WSAudioFrame) async -> TTSFrameOutcome {
        guard let turnID = attributionTurnID else {
            return .dropped(turnID: nil, reason: .unknownTurn, errorDescription: "no active turn (missing ai.tts.start)")
        }
        return await onAudio(
            TurnKeyedAudioFrame(turnID: turnID, sequence: frame.sequence, payload: frame.payload)
        )
    }

    /// 已带归属的帧：用于测试与将来的「帧自带 turn_id」形态。
    ///
    /// ## 路由规则
    /// 1. `turnID == nil` → 丢弃（不再支持 legacy）
    /// 2. `turnID` 是 `.active` → 解码后播放
    /// 3. `turnID` 是 `.superseded` → 丢弃
    /// 4. `turnID` 未知 → 丢弃（不再支持 playAsLegacy）
    @discardableResult
    public func onAudio(_ frame: TurnKeyedAudioFrame) async -> TTSFrameOutcome {
        guard let turnID = frame.turnID else {
            return .dropped(turnID: nil, reason: .unknownTurn, errorDescription: "frame has no turn_id")
        }

        guard let state = turnRegistry[turnID] else {
            return .dropped(turnID: turnID, reason: .unknownTurn, errorDescription: "turn_id not registered (missing ai.tts.start)")
        }

        guard state == .active else {
            return .dropped(turnID: turnID, reason: .superseded, errorDescription: nil)
        }

        return await playKeyed(frame, turnID: turnID)
    }

    // MARK: - Private Helpers

    private func playKeyed(_ frame: TurnKeyedAudioFrame, turnID: String) async -> TTSFrameOutcome {
        guard !frame.payload.isEmpty else {
            return .dropped(turnID: turnID, reason: .decodeFailed, errorDescription: "empty payload")
        }

        do {
            let pcm = try await decoder.decode(frame)
            await sink.play(pcm: pcm)
            return .played(turnID: turnID)
        } catch {
            return .dropped(
                turnID: turnID,
                reason: .decodeFailed,
                errorDescription: String(describing: error)
            )
        }
    }
}
