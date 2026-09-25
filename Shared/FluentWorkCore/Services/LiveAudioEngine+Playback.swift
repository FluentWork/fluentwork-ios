@preconcurrency import AVFoundation
import FluentWorkObjCSupport
import Foundation

extension LiveAudioEngine {
    /// 播放已经解码好的 PCM（`AudioSink.play(pcm:)`）。**引擎唯一的播放入口。**
    ///
    /// 两道守卫：`playbackRetired` —— 会话已结束而 socket 还在投递时，不能让一个在途帧把它
    /// 重新拉起来；`makePCMBuffer` 的长度校验 —— 它是畸形 payload 与「一个永远播不出来的
    /// scheduledBuffer」之间唯一的东西。
    ///
    /// **这里没有按序列号的水印，这是有意的。** 曾经有两道（`AudioPlaybackGate` 与
    /// `BargeInAudioGate`），都删了，理由相同：序列号说不出一个帧属于哪一轮。
    public func play(pcm: Data) async {
        guard !playbackRetired else { return }

        guard let buffer = makePCMBuffer(from: pcm) else {
            continuation.yield(.failed("scheduling dropped: PCM length \(pcm.count) not multiple of 2"))
            return
        }

        guard startPlaybackIfNeeded() else { return }
        enqueueWithoutWaiting(buffer)
    }

    /// 排队一个 buffer 并立即返回。
    ///
    /// 刻意**不用** `await playerNode.scheduleBuffer(...)`，那是编辑器会建议的替代写法。
    /// 那个重载只在 buffer 被**渲染**完之后才返回，await 它会把网关的轮次末突发按真实时间
    /// 拉平：一个 32 秒的回复以一次突发到达，而中间件的传输循环会在这一个调用里耗掉那 32 秒
    /// —— 文本帧、控制帧和下一轮的音频全排在它后面。
    private func enqueueWithoutWaiting(_ buffer: AVAudioPCMBuffer) {
        scheduledBufferCount += 1
        playerNode.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }

    /// 把一个 buffer 排到播放节点上，并确保真的有东西在播它。
    ///
    /// `scheduleBuffer` 只入队 —— 一个从未启动的节点什么都播不出来。`interruptNow()` 为打断
    /// 而停了节点，所以这里也得在下一帧把它带回来。
    ///
    /// 返回节点是否排在一张正在跑的引擎上；每个调用方都必须把 `false` 当成「什么都不会播」。
    /// 之所以返回一个值而不是尽力而为，是因为它守的那一行：`AVAudioPlayerNode.play()` 不抛，
    /// 在已停的引擎上它会 raise 一个**未捕获的 `NSException`** 并终止 App。
    private func startPlaybackIfNeeded() -> Bool {
        attachPlayerIfNeeded()
        if !engine.isRunning {
            do {
                try startEngine(engine)
            } catch {
                continuation.yield(.failed("playback engine did not start: \(error.localizedDescription)"))
                return false
            }
        }
        guard engine.isRunning else {
            continuation.yield(.failed("playback engine is not running; dropped frame"))
            return false
        }
        guard playerIsConnected() else {
            continuation.yield(.failed("playback node is detached from the engine; dropped frame"))
            playerAttached = false
            return false
        }
        if playbackPaused {
            // 只排队：结束练习的取消必须能从这里接着播。
            return true
        }
        if !playerNode.isPlaying {
            // 节点没东西可播入时 `play()` 会 raise 而不是返回，而「没东西可播入」不是这一层
            // 读得到的状态。上面每一条前置条件都在收窄这个窗口；这一句是让窗口变得不重要。
            var raised: NSError?
            guard FWTryCatch({ self.playerNode.play() }, &raised) else {
                continuation.yield(.failed("player start raised: \(raised?.localizedDescription ?? "unknown")"))
                return false
            }
        }
        return true
    }

    /// 播放节点是否挂**在这一张**引擎上。
    ///
    /// `playerAttached` 是这个 actor 缓存的信念，`playerNode.engine` 是 AVFoundation 实际会查
    /// 的东西。两者恰在图被从底下拆掉时不一致 —— deactivate 音频会话就会那样 —— 而 raise
    /// 出来的 "disconnected state" 说的正是这个条件，不是引擎的运行状态。
    private func playerIsConnected() -> Bool {
        guard playerAttached else { return false }
        return playerNode.engine === engine
    }

    public func interruptNow() async {
        lastInterruptRequestedAt = clock.now
        playbackPaused = false
        if playerAttached {
            playerNode.stop()
            playerNode.reset()
        }
    }

    public func pausePlayback() async {
        playbackPaused = true
        if playerAttached {
            playerNode.pause()
        }
    }

    public func resumePlayback() async {
        guard !playbackRetired else { return }
        playbackPaused = false
        guard engine.isRunning, playerIsConnected() else { return }
        if !playerNode.isPlaying {
            var raised: NSError?
            _ = FWTryCatch({ self.playerNode.play() }, &raised)
        }
    }

    /// 供测试取快照：确认框的暂停必须在不退休播放的前提下保持住。
    public func isPlaybackPaused() -> Bool {
        playbackPaused
    }

    /// 供测试取快照：上一次 `interruptNow()` 的时刻。
    public func lastInterruptInstant() -> ContinuousClock.Instant? {
        lastInterruptRequestedAt
    }

    func attachPlayerIfNeeded() {
        attachPlayer(playerNode, isAttached: &playerAttached)
    }

    func attachKeepAliveIfNeeded() {
        attachPlayer(keepAliveNode, isAttached: &keepAliveAttached)
    }

    /// 把一个播放节点挂到主混音器上。
    ///
    /// 刻意**不**包在 `FWTryCatch` 里，与 `play()` 不同：这里的格式是源节点自己的输出格式，
    /// `AVAudioEngine` 总是接受它（混音器会重采样）。所以这里要防的 raise 是推测性的，
    /// 而守卫本身不是免费的 —— `.failed` 会结束中间件的音频泵，把一个单会话的播放问题
    /// 变成之后每一个会话都静音。
    ///
    /// 必须在 `engine.start()` **之前**调：在跑着的引擎上改图会 raise 而不是返回错误。
    private func attachPlayer(_ node: AVAudioPlayerNode, isAttached attached: inout Bool) {
        guard !attached else { return }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: Self.targetFormat)
        attached = true
    }

    /// 在任何东西向麦克风要数据**之前**把渲染循环转起来：输入跟着输出走，而 `.connecting`
    /// 等麦克风自证，所以一个什么都不播的会话根本起不来。这一句就是打破那个死结的。
    ///
    /// 六种结局，事件带着是哪一种：循环可能压根没挂上过，而没有 `detail` 就分不出那和
    /// 「挂上了但没用」。
    ///
    /// - Returns: 循环是否被要求启动，供调用方记录。
    func startKeepAlive() -> (started: Bool, detail: String) {
        attachKeepAliveIfNeeded()
        guard keepAliveAttached else {
            return (false, "keep-alive node not attached")
        }
        guard let buffer = keepAliveBuffer else {
            return (false, "keep-alive buffer could not be built")
        }
        guard engine.isRunning else {
            // `start()` 返回后这么快引擎又停了，有两条途径，需要不同的修法：系统中断了我们，
            // 或这个 App 里的什么东西从底下重配了共享会话。两者都让 `isRunning` 变 false 而
            // 不在任何地方留下错误，所以 detail 必须说出是哪一种。
            return (
                false,
                "engine not running (interrupted=\(isSystemInterrupted), \(Self.describeSession()))"
            )
        }
        guard keepAliveNode.engine === engine else {
            keepAliveAttached = false
            return (false, "keep-alive node detached from the engine")
        }
        if keepAliveNode.isPlaying {
            return (true, "already playing")
        }
        if !keepAliveBufferScheduled {
            // 用 `.loops` 而不是一次性：如果输入真的跟着输出走，一次性的那一脚会在它排空的
            // 那一刻重新安静下来 —— 同一个静音，四十毫秒之后。
            keepAliveNode.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
            keepAliveBufferScheduled = true
        }
        // 节点没东西可播入时会 raise 而不是返回，即引擎报告 `isRunning` 而它的渲染循环
        // 从未 tick 过。
        var raised: NSError?
        guard FWTryCatch({ keepAliveNode.play() }, &raised) else {
            return (false, "play() raised: \(raised?.localizedDescription ?? "unknown")")
        }
        return (true, "playing")
    }

    /// 把裸的 16 kHz mono interleaved PCM16 字节包成适合 `AVAudioPlayerNode.scheduleBuffer`
    /// 的 `AVAudioPCMBuffer`。
    ///
    /// 返回的 buffer 的 `frameLength` 是 `payload.count / 2`。payload 长度不是 2 的倍数时返回
    /// `nil`，好让调用方发一个 `.failed` 事件，而不是把播放队列搞坏。
    private func makePCMBuffer(from payload: Data) -> AVAudioPCMBuffer? {
        guard !payload.isEmpty, payload.count.isMultiple(of: 2) else { return nil }
        let frameCount = AVAudioFrameCount(payload.count / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: frameCount) else {
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
}
