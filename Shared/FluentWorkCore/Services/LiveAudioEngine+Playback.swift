@preconcurrency import AVFoundation
import FluentWorkObjCSupport
import Foundation

extension LiveAudioEngine {
    /// Plays PCM that a decoder has already produced (`AudioSink.play(pcm:)`).
    ///
    /// **这是引擎唯一的播放入口。** 带轮次归属的帧走这条：`TTSPlaybackCoordinator`
    /// 判定这一帧属于一个活跃的轮次，并解码好交给这里。
    ///
    /// 两道守卫：`playbackRetired` —— 会话已经结束、而 socket 还在投递时，不能让一个
    /// 在途帧把它重新拉起来；`makePCMBuffer` 的长度校验 —— 它是畸形 payload 与
    /// 「永远播不出来的一个 scheduledBuffer」之间唯一的东西。
    ///
    /// **这里没有按序列号的水印，这是有意的。** 曾经有两道（`AudioPlaybackGate` 与
    /// `BargeInAudioGate`），都删了，理由相同：序列号说不出一个帧属于哪一轮。
    /// 轮次归属由协调器在正确的轴上回答 —— 被作废那一轮的帧根本到不了这里。
    public func play(pcm: Data) async {
        guard !playbackRetired else { return }

        guard let buffer = makePCMBuffer(from: pcm) else {
            continuation.yield(.failed("scheduling dropped: PCM length \(pcm.count) not multiple of 2"))
            return
        }

        guard startPlaybackIfNeeded() else { return }
        enqueueWithoutWaiting(buffer)
    }

    /// Queues a buffer and returns immediately.
    ///
    /// Deliberately **not** `await playerNode.scheduleBuffer(...)`, which is the
    /// alternative the editor suggests here. That overload returns only once the
    /// buffer has been *rendered*, so awaiting it would pace the gateway's
    /// turn-end burst to real time: a 32-second reply arrives as one burst, and
    /// the middleware's transport loop would spend those 32 seconds inside this
    /// call — text frames, control frames and the next turn's audio all queued
    /// behind it.
    private func enqueueWithoutWaiting(_ buffer: AVAudioPCMBuffer) {
        scheduledBufferCount += 1
        playerNode.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }

    /// Queues audio onto the player node and makes sure something is actually
    /// playing it.
    ///
    /// `scheduleBuffer` only enqueues — a node that was never started plays
    /// nothing. `interruptNow()` stops the node for barge-in, so this also has
    /// to bring it back on the next frame.
    ///
    /// Returns whether the node is queued onto a running engine; every caller
    /// must treat `false` as "nothing will play". The reason this returns a
    /// value instead of being best-effort is the line it guards:
    ///
    /// `AVAudioPlayerNode.play()` does not throw. On a stopped engine it raises
    /// an **uncaught `NSException`** ("player started when in a disconnected
    /// state") and terminates the app.
    private func startPlaybackIfNeeded() -> Bool {
        attachPlayerIfNeeded()
        if !engine.isRunning {
            do {
                try startEngineForPlayback(engine)
            } catch {
                continuation.yield(.failed("playback engine did not start: \(error.localizedDescription)"))
                return false
            }
        }
        guard engine.isRunning else {
            continuation.yield(.failed("playback engine is not running; dropped frame"))
            return false
        }
        // `playerAttached` is this actor's cached belief; `playerNode.engine` is
        // what AVFoundation will actually consult. They disagree exactly when
        // the graph was torn down underneath us — deactivating the audio session
        // does that — and "disconnected state" in the raised exception is this
        // condition, not the engine's run state.
        guard playerNode.engine === engine else {
            continuation.yield(.failed("playback node is detached from the engine; dropped frame"))
            playerAttached = false
            return false
        }
        if playbackPaused {
            // Schedule-only: cancel of 结束练习 must continue from here.
            return true
        }
        if !playerNode.isPlaying {
            // `play()` raises rather than returning when the node has nothing to
            // play into, and "has nothing to play into" is not a state this
            // layer can read. Every precondition above narrows the window; this
            // is what makes the window not matter.
            var raised: NSError?
            guard FWTryCatch({ self.playerNode.play() }, &raised) else {
                continuation.yield(.failed("player start raised: \(raised?.localizedDescription ?? "unknown")"))
                return false
            }
        }
        return true
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
        guard playerAttached, engine.isRunning, playerNode.engine === engine else { return }
        if !playerNode.isPlaying {
            var raised: NSError?
            _ = FWTryCatch({ self.playerNode.play() }, &raised)
        }
    }

    /// Snapshot for tests: confirmation-dialog pause must hold without retiring playback.
    public func isPlaybackPaused() -> Bool {
        playbackPaused
    }

    /// Snapshot of the last `interruptNow()` instant for barge-in latency tests.
    /// Public on the actor so tests can read it without exposing the raw clock.
    public func lastInterruptInstant() -> ContinuousClock.Instant? {
        lastInterruptRequestedAt
    }

    /// Deliberately *not* wrapped in `FWTryCatch`, unlike `play()`.
    ///
    /// The format here is the source node's own output format, which
    /// `AVAudioEngine` always accepts — the mixer resamples. So the raise this
    /// would guard is speculative, while the guard itself is not free: `.failed`
    /// ends the middleware's audio pump for the rest of the process, which would
    /// turn a one-session playback problem into every later session going
    /// silent.
    func attachPlayerIfNeeded() {
        guard !playerAttached else { return }
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: Self.targetFormat)
        playerAttached = true
    }

    /// Attaches the keep-alive player. Same window as the TTS player — **before
    /// `engine.start()`, never after** — because graph mutation on a running
    /// engine raises rather than returning an error.
    func attachKeepAliveIfNeeded() {
        guard !keepAliveAttached else { return }
        engine.attach(keepAliveNode)
        engine.connect(keepAliveNode, to: engine.mainMixerNode, format: Self.targetFormat)
        keepAliveAttached = true
    }

    /// Starts the render cycle before anything is asked of the microphone: the
    /// input follows the output, and `.connecting` waits for the microphone to
    /// prove itself, so a session that never plays anything could not start at
    /// all. This is what breaks that circle.
    ///
    /// Six outcomes, and the event carries which one happened: the cycle may
    /// never have been attached at all, and without a `detail` there is no way
    /// to tell that from "attached and useless".
    ///
    /// - Returns: whether the cycle was asked to start, for the caller's log.
    func startKeepAlive() -> (started: Bool, detail: String) {
        attachKeepAliveIfNeeded()
        guard keepAliveAttached else {
            return (false, "keep-alive node not attached")
        }
        guard let buffer = keepAliveBuffer else {
            return (false, "keep-alive buffer could not be built")
        }
        guard engine.isRunning else {
            // Two ways an engine can be stopped again this soon after `start()`
            // returned, and they need different fixes: the system interrupted
            // us, or something in this app reconfigured the shared session out
            // from under us. Both leave `isRunning` false with no error
            // anywhere, so the detail has to say which.
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
            // `.loops` rather than a one-shot: if the input really follows the
            // output, a single kick would go quiet again the moment it drained
            // — the same silence, forty milliseconds later.
            keepAliveNode.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
            keepAliveBufferScheduled = true
        }
        // Raises rather than returns when the node has nothing to play into,
        // i.e. the engine reports `isRunning` while its render cycle has never
        // ticked.
        var raised: NSError?
        guard FWTryCatch({ keepAliveNode.play() }, &raised) else {
            return (false, "play() raised: \(raised?.localizedDescription ?? "unknown")")
        }
        return (true, "playing")
    }

    /// Wraps raw 16 kHz mono interleaved PCM16 bytes in an `AVAudioPCMBuffer`
    /// suitable for `AVAudioPlayerNode.scheduleBuffer`.
    ///
    /// The returned buffer's `frameLength` is `payload.count / 2`. If the
    /// payload length is not a multiple of 2, returns `nil` so the caller can
    /// surface a `.failed` event instead of corrupting the player queue.
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
