extension LiveAudioEngine {
    func startInterruptionObservation() {
        interruptionObserver.start { [weak self] kind in
            await self?.handleInterruption(kind)
        }
    }

    func stopInterruptionObservation() {
        interruptionObserver.stop()
    }

    /// 把 AVAudioSession 的中断/路由变化映射成 `AudioEngineEvent`。
    /// **不** deactivate 音频会话 —— 采集在一次电话式中断前后保持配置，所以恢复时不必重建图。
    func handleInterruption(_ kind: AudioInterruptionKind) {
        switch kind {
        case .began:
            isSystemInterrupted = true
            // 从这里开始计数，好让 `.ended` 时出来的那个数是关于**这一次**中断的。
            interruptionDroppedBuffers = 0
            _ = speechTracker.reset()
            if playerAttached {
                playerNode.pause()
            }
            continuation.yield(.interruptedBySystem)
        case .ended(let shouldResume):
            // 只在 iOS 说可以的时候恢复说话会话。**不要** `playerNode.play()` ——
            // `interruptedBySystem` 已经让机器停了播放，恢复落在 `waitingUser`。
            //
            // iOS 不给恢复时说点什么，这是陷阱不是谨慎：`.began` 把机器停在了它的 suspended
            // 相位，而一个 suspended 的机器只放行五个事件 —— 所以既没有 `.systemInterruptEnded`
            // 也没有失败时，任何路径都抬不起那个悬挂。结束它是诚实的结果：`.failed` 是仍然能
            // 落地的五个事件之一，它以可重试的错误到达用户，而不是一次冻结。
            guard shouldResume else {
                continuation.yield(.failed("音频被系统中断，本轮练习已停止"))
                return
            }
            isSystemInterrupted = false
            // 在抬起之前，好让这个计数归属刚刚结束的那次中断，而不是下一次。
            continuation.yield(.captureInterruptionLifted(droppedBuffers: interruptionDroppedBuffers))
            continuation.yield(.systemInterruptEnded)
        case .routeChanged(let reason):
            continuation.yield(.routeChanged(reason))
        }
    }
}
