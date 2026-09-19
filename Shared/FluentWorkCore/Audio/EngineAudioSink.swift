import AVFoundation
import FluentWorkNetworking
import Foundation

/// 生产环境的音频播放实现，封装 `AVAudioPlayerNode` 的播放逻辑
///
/// ## 职责
/// 1. PCM16 数据 → `AVAudioPCMBuffer` 转换
/// 2. 缓冲入队到播放节点
/// 3. 管理播放节点的生命周期（启动/停止/重置）
///
/// ## 从 `LiveAudioEngine` 迁移
/// 原本散落在 `LiveAudioEngine` 中的 `play(frame:)` / `makePCMBuffer` /
/// `enqueueWithoutWaiting` 逻辑现在集中在这里，引擎本身退化为"被 sink 调用的播放器"。
public actor EngineAudioSink: AudioSink {
    private let playerNode: AVAudioPlayerNode
    private let engine: AVAudioEngine
    private let targetFormat: AVAudioFormat
    private let decoder: any WSAudioFrameDecoder
    private var playerAttached = false
    
    /// 用于向外报告错误的回调（可选）
    private let onError: (@Sendable (String) async -> Void)?
    
    public init(
        playerNode: AVAudioPlayerNode,
        engine: AVAudioEngine,
        decoder: any WSAudioFrameDecoder,
        onError: (@Sendable (String) async -> Void)? = nil
    ) {
        self.playerNode = playerNode
        self.engine = engine
        self.decoder = decoder
        self.onError = onError
        
        // 16kHz mono PCM16 - 与 LiveAudioEngine.targetFormat 一致
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
    }
    
    public func play(pcm: Data) async {
        guard let buffer = makePCMBuffer(from: pcm) else {
            await onError?("PCM buffer creation failed: length \(pcm.count) not multiple of 2")
            return
        }
        
        guard startPlaybackIfNeeded() else { return }
        enqueueWithoutWaiting(buffer)
    }
    
    public func play(legacy frame: WSAudioFrame) async {
        let pcm: Data
        do {
            pcm = try await decoder.decode(frame)
        } catch {
            await onError?("decode failed: \(error)")
            return
        }
        
        guard let buffer = makePCMBuffer(from: pcm) else {
            await onError?("scheduling dropped: PCM length \(pcm.count) not a multiple of 2")
            return
        }
        
        guard startPlaybackIfNeeded() else { return }
        enqueueWithoutWaiting(buffer)
    }
    
    public func interruptNow() async {
        guard playerAttached else { return }
        playerNode.stop()
        playerNode.reset()
    }

    // MARK: - Private
    
    /// 将 PCM16 数据转换为 `AVAudioPCMBuffer`
    ///
    /// - Parameter payload: PCM16 格式音频数据（每样本 2 字节）
    /// - Returns: 音频缓冲，如果长度不是偶数则返回 nil
    ///
    /// ## 不变量
    /// - `payload.count` 必须是 2 的倍数
    /// - 返回的 `frameLength` = `payload.count / 2`
    private func makePCMBuffer(from payload: Data) -> AVAudioPCMBuffer? {
        guard !payload.isEmpty, payload.count.isMultiple(of: 2) else { return nil }
        let frameCount = AVAudioFrameCount(payload.count / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        guard let target = buffer.audioBufferList.pointee.mBuffers.mData else { return nil }
        return payload.withUnsafeBytes { raw -> AVAudioPCMBuffer? in
            guard let source = raw.baseAddress else { return nil }
            memcpy(target, source, payload.count)
            return buffer
        }
    }
    
    /// 将缓冲入队到播放节点（立即返回，不等待渲染完成）
    ///
    /// ## 为什么不用 `await scheduleBuffer`
    /// `scheduleBuffer` 的 async 重载会等到缓冲**渲染完成**才返回。
    /// 如果等待它，一个 32 秒的回复会让 transport loop 阻塞 32 秒，
    /// 所有后续帧（文本、控制帧、下一轮音频）都会堆积在后面。
    private func enqueueWithoutWaiting(_ buffer: AVAudioPCMBuffer) {
        playerNode.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }
    
    /// 确保播放节点已附加到引擎且引擎正在运行
    ///
    /// - Returns: 是否可以安全地调用 `playerNode.play()`
    ///
    /// ## 为什么需要这个
    /// `AVAudioPlayerNode.play()` 在引擎停止时会抛出 **NSException** 而非 Swift Error，
    /// 直接崩溃进程。这个守卫确保引擎已启动。
    @discardableResult
    private func startPlaybackIfNeeded() -> Bool {
        attachPlayerIfNeeded()
        
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                Task { await onError?("playback engine did not start: \(error.localizedDescription)") }
                return false
            }
        }
        
        guard engine.isRunning else {
            Task { await onError?("playback engine is not running; dropped frame") }
            return false
        }
        
        guard playerNode.engine != nil else {
            Task { await onError?("player node not attached despite playerAttached=true") }
            return false
        }
        
        if !playerNode.isPlaying {
            playerNode.play()
        }
        
        return true
    }
    
    /// 首次播放时将播放节点附加到引擎
    private func attachPlayerIfNeeded() {
        guard !playerAttached else { return }
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: targetFormat)
        playerAttached = true
    }
}
