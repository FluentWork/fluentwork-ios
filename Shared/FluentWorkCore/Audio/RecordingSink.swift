import FluentWorkNetworking
import Foundation

/// 测试用的音频播放记录器，不产生实际声音
///
/// ## 用途
/// 在单元测试中验证 `TTSPlaybackCoordinator` 的播放决策：
/// - 哪些帧被播放了
/// - 哪些帧被丢弃了
/// - 播放顺序是否正确
///
/// ## 示例
/// ```swift
/// let sink = RecordingSink()
/// let coordinator = TTSPlaybackCoordinator(decoder: PassthroughDecoder(), sink: sink)
/// await coordinator.onAudio(frame1)
/// await coordinator.onAudio(frame2)
/// #expect(await sink.playedSequenceNumbers == [0, 1])
/// ```
public actor RecordingSink: AudioSink {
    public struct PlayCall: Equatable, Sendable {
        public var pcm: Data
        public var timestamp: Date
        
        public init(pcm: Data, timestamp: Date = Date()) {
            self.pcm = pcm
            self.timestamp = timestamp
        }
    }
    
    public struct LegacyPlayCall: Equatable, Sendable {
        public var sequence: UInt32
        public var payloadLength: Int
        public var timestamp: Date
        
        public init(sequence: UInt32, payloadLength: Int, timestamp: Date = Date()) {
            self.sequence = sequence
            self.payloadLength = payloadLength
            self.timestamp = timestamp
        }
    }
    
    public private(set) var playCalls: [PlayCall] = []
    public private(set) var legacyPlayCalls: [LegacyPlayCall] = []
    public private(set) var interruptCount = 0

    public init() {}
    
    public func play(pcm: Data) async {
        playCalls.append(PlayCall(pcm: pcm))
    }
    
    public func play(legacy frame: WSAudioFrame) async {
        legacyPlayCalls.append(LegacyPlayCall(
            sequence: frame.sequence,
            payloadLength: frame.payload.count
        ))
    }
    
    public func interruptNow() async {
        interruptCount += 1
    }

    // MARK: - 测试辅助方法
    
    /// 已播放的序列号列表（legacy 路径）
    public var playedSequenceNumbers: [UInt32] {
        legacyPlayCalls.map(\.sequence)
    }
    
    /// 已播放的 PCM 数据总字节数
    public var totalPCMBytes: Int {
        playCalls.reduce(0) { $0 + $1.pcm.count }
    }
    
    /// 清空所有记录
    public func reset() {
        playCalls.removeAll()
        legacyPlayCalls.removeAll()
        interruptCount = 0
    }
}
