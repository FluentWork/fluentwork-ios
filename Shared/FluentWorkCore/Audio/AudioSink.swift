import Foundation
import FluentWorkNetworking

/// 音频播放的抽象层，用于将播放逻辑从具体实现中解耦
///
/// ## 设计目的
///
/// 1. **可测试性**: 通过注入 `RecordingSink` 可以在单元测试中验证播放决策
/// 2. **关注点分离**: `TTSPlaybackCoordinator` 只需关注"播什么/丢什么"的决策
///
/// ## 实现
///
/// - 生产环境: `LiveAudioEngine` 自己就是这个 sink（`AudioEngineProtocol: AudioSink`）
/// - 测试环境: `RecordingSink` - 记录播放调用但不产生声音
public protocol AudioSink: Sendable {
    /// 播放 PCM16 音频数据
    ///
    /// - Parameter pcm: 16kHz 单声道 PCM16 格式的音频数据
    func play(pcm: Data) async
    
    /// 立即中断当前播放，清空已调度的缓冲
    func interruptNow() async
}
