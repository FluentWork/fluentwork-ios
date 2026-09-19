import Foundation
import FluentWorkNetworking

/// TTS 播放协调器：基于 `turn_id` 路由下行音频帧，支持打断与过渡期双轨兼容。
///
/// ## 设计目标
///
/// 1. **修复串音 bug**：用户打断后，前一轮的残留帧不再播放（P0-11 根因）。
/// 2. **零行为变化过渡**：`turn_id == nil` 的帧走 legacy 路径，后端未改造前仍出声。
/// 3. **可测试决策**：通过 `RecordingSink` 验证播/丢逻辑，不依赖真实音频设备。
/// 4. **真实解码 seam**：带 `turn_id` 的帧经 `AudioFrameDecoder` 解码成 PCM 后播放，
///    杜绝「start 认领后路由进一台录音机」的 2026-09-12 静音事故重演。
///
/// ## 核心机制
///
/// ### Turn Registry（轮次注册表）
/// - `onStart(turnID:)` 注册新轮次为 `.active`，并 supersede 前一轮。
/// - `onInterrupt(turnID:)` 将轮次标记为 `.superseded`。
/// - `onEnd(turnID:)` 注销轮次。
///
/// ### 音频帧路由
/// - `turnID != nil` 且 `.active` → 解码后播放。
/// - `turnID != nil` 且 `.superseded` → 丢弃。
/// - `turnID != nil` 且未知 → 按策略处理（默认丢弃）。
/// - `turnID == nil` → 透传到 legacy 路径（行为零变化）。
///
/// 注意：同一轮内帧不在此排序。下行帧走 WSS，按到达顺序进入 `onAudio`；
/// 乱序重排不是本协调器的职责（目标设计里也没有），交由 decoder/sink 处理。
public actor TTSPlaybackCoordinator {
    /// 轮次状态
    private enum TurnState: Sendable, Equatable {
        case active
        case superseded
    }

    /// 轮次注册表：turn_id → state
    private var turnRegistry: [String: TurnState] = [:]

    /// 当前活跃的轮次 ID（最近一次 onStart）
    private var activeTurnID: String?

    /// 唯一解码 seam：payload → 16k mono PCM16
    private let decoder: any AudioFrameDecoder

    /// 音频播放 sink
    private let sink: any AudioSink

    /// 未知 turn_id 的处理策略
    public enum UnknownTurnPolicy: Sendable {
        case drop         // 丢弃（保守，默认）
        case playAsLegacy // 当作 legacy 播放（激进）
    }
    private let unknownTurnPolicy: UnknownTurnPolicy

    public init(
        decoder: any AudioFrameDecoder,
        sink: any AudioSink,
        unknownTurnPolicy: UnknownTurnPolicy = .drop
    ) {
        self.decoder = decoder
        self.sink = sink
        self.unknownTurnPolicy = unknownTurnPolicy
    }

    // MARK: - Turn Lifecycle

    /// 开始新轮次。
    ///
    /// - 自动 supersede 前一个活跃轮次（即使未显式 interrupt）
    /// - 注册新 turn_id 为 `.active`
    public func onStart(turnID: String) async {
        if let previousTurn = activeTurnID {
            turnRegistry[previousTurn] = .superseded
        }
        turnRegistry[turnID] = .active
        activeTurnID = turnID
    }

    /// 打断当前轮次。
    ///
    /// - 将指定 turn_id 标记为 `.superseded`，后续该 turn_id 的帧将被丢弃
    /// - 立即中断 sink 的 in-flight 缓冲
    public func onInterrupt(turnID: String) async {
        turnRegistry[turnID] = .superseded
        if activeTurnID == turnID {
            activeTurnID = nil
        }
        await sink.interruptNow()
    }

    /// 结束轮次。
    ///
    /// 从注册表注销 turn_id；对应 `ai.tts.end`。
    public func onEnd(turnID: String) async {
        turnRegistry[turnID] = nil
        if activeTurnID == turnID {
            activeTurnID = nil
        }
    }

    // MARK: - Audio Frame Routing

    /// 处理音频帧。
    ///
    /// ## 路由规则
    /// 1. `turnID == nil` → legacy 路径（透传）
    /// 2. `turnID` 是 `.active` → 解码后播放
    /// 3. `turnID` 是 `.superseded` → 丢弃
    /// 4. `turnID` 未知 → 按 policy 处理
    public func onAudio(_ frame: TurnKeyedAudioFrame) async {
        guard let turnID = frame.turnID else {
            await playLegacy(frame)
            return
        }

        guard let state = turnRegistry[turnID] else {
            await handleUnknownTurn(frame)
            return
        }

        guard state == .active else {
            return
        }

        await playKeyed(frame)
    }

    // MARK: - Private Helpers

    private func playLegacy(_ frame: TurnKeyedAudioFrame) async {
        let legacyFrame = WSAudioFrame(
            sequence: frame.sequence,
            payload: frame.payload
        )
        await sink.play(legacy: legacyFrame)
    }

    private func playKeyed(_ frame: TurnKeyedAudioFrame) async {
        do {
            let pcm = try await decoder.decode(frame)
            await sink.play(pcm: pcm)
        } catch {
            // 解码失败埋点（tts_decoder_failed）由 caller（middleware）承担；
            // coordinator 不持有 tracker，这里静默丢弃。
        }
    }

    private func handleUnknownTurn(_ frame: TurnKeyedAudioFrame) async {
        switch unknownTurnPolicy {
        case .drop:
            return
        case .playAsLegacy:
            await playLegacy(frame)
        }
    }
}
