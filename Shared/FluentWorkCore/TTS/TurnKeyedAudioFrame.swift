import Foundation
import FluentWorkNetworking

/// 携带 turn_id 的音频帧，用于支持基于会话轮次的播放控制
///
/// ## 设计动机
///
/// 现状 `WSAudioFrame` 只有 `sequence` 和 `payload`，无法区分哪些帧属于哪一轮对话。
/// 当用户打断（barge-in）发生时，后端会继续推送前一轮的残留帧，客户端需要：
///
/// 1. **识别过期轮次**：通过 `turn_id` 与当前活跃轮次比对
/// 2. **丢弃而非播放**：避免串音（用户已打断，不应再听到上一轮的内容）
///
/// ## 生命周期
///
/// - 当后端发送 `ai.tts.start` 时，客户端记录 `turn_id`
/// - 后续二进制帧（`case .audio`）通过归属指针关联到该 `turn_id`
/// - 用户打断时，该 `turn_id` 被标记为 superseded，后续帧静默丢弃
public struct TurnKeyedAudioFrame: Sendable, Equatable {
    /// 会话轮次标识符，与 `ai.tts.start` 中的 `turn_id` 对应
    public let turnID: String?
    
    /// 音频帧序号（单调递增）
    public let sequence: UInt32
    
    /// PCM16 音频数据（16kHz 单声道）
    public let payload: Data
    
    public init(turnID: String?, sequence: UInt32, payload: Data) {
        self.turnID = turnID
        self.sequence = sequence
        self.payload = payload
    }
}
