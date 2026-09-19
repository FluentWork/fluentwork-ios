import Foundation

/// 音频播放的抽象层，用于将播放逻辑从具体实现中解耦
///
/// ## 设计目的
///
/// 1. **可测试性**: 通过注入 `RecordingSink` 可以在单元测试中验证播放决策，
///    而无需启动真实的 `AVAudioEngine`
/// 2. **关注点分离**: `TTSPlaybackCoordinator` 只需关注"播什么/丢什么"的决策，
///    播放细节（PCM 缓冲构造、入队）由 sink 负责
/// 3. **过渡期兼容**: `play(legacy:)` 支持无 `turn_id` 的旧帧，
///    保证在后端补充 turn_id 之前系统仍能出声
///
/// ## 实现
///
/// - 生产环境: `EngineAudioSink` - 封装 `AVAudioPlayerNode` 的播放逻辑
/// - 测试环境: `RecordingSink` - 记录播放调用但不产生声音
public protocol AudioSink: Sendable {
    /// 播放 PCM16 音频数据
    ///
    /// - Parameter pcm: 16kHz 单声道 PCM16 格式的音频数据
    ///
    /// ## 前置条件
    /// - `pcm.count` 必须是偶数（每个样本 2 字节）
    /// - 采样率假定为 16kHz（由上游解码器保证）
    func play(pcm: Data) async
    
    /// 播放兼容旧协议的音频帧（无 turn_id）
    ///
    /// - Parameter frame: 来自旧协议的音频帧，`payload` 直接视为 PCM16
    ///
    /// ## 过渡期语义
    /// 在后端开始为二进制帧添加 `turn_id` 之前，所有帧走此路径，
    /// 行为与当前 `audioEngine.play(frame:)` 完全一致
    func play(legacy frame: WSAudioFrame) async
    
    /// 立即中断当前播放，清空已调度的缓冲
    ///
    /// 用于用户打断（barge-in）场景
    func interruptNow() async
    
    /// 等待所有已调度的音频播放完成
    ///
    /// 用于会话结束时的优雅关闭
    func drain() async
}
