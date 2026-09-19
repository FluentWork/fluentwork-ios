import FluentWorkNetworking
import Foundation

/// 测试用的音频播放记录器，不产生实际声音
///
/// ## 用途
/// 在单元测试中验证 `TTSPlaybackCoordinator` 的播放决策：
/// - 哪些帧被播放了
/// - 哪些帧被丢弃了
/// - 播放顺序是否正确
public actor RecordingSink: AudioSink {
    public struct PlayCall: Equatable, Sendable {
        public var pcm: Data
        public var timestamp: Date
        
        public init(pcm: Data, timestamp: Date = Date()) {
            self.pcm = pcm
            self.timestamp = timestamp
        }
    }
    
    public private(set) var playCalls: [PlayCall] = []
    public private(set) var interruptCount = 0

    public init() {}
    
    public func play(pcm: Data) async {
        playCalls.append(PlayCall(pcm: pcm))
    }
    
    public func interruptNow() async {
        interruptCount += 1
    }

    // MARK: - 测试辅助方法
    
    /// 已播放的 PCM 数据总字节数
    public var totalPCMBytes: Int {
        playCalls.reduce(0) { $0 + $1.pcm.count }
    }
    
    /// 清空所有记录
    public func reset() {
        playCalls.removeAll()
        interruptCount = 0
    }
}
