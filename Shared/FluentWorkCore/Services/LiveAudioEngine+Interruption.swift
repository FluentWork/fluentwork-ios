extension LiveAudioEngine {
    func startInterruptionObservation() {
        interruptionObserver.start { [weak self] kind in
            await self?.handleInterruption(kind)
        }
    }

    func stopInterruptionObservation() {
        interruptionObserver.stop()
    }

    /// Maps AVAudioSession interruption / route changes onto `AudioEngineEvent`.
    /// Does not deactivate the audio session — capture stays configured across a
    /// phone-call-style interrupt so resume does not rebuild the graph.
    func handleInterruption(_ kind: AudioInterruptionKind) {
        switch kind {
        case .began:
            isSystemInterrupted = true
            // Counted from here so the number that comes out at `.ended` is
            // about *this* interruption, not every one this engine has seen.
            interruptionDroppedBuffers = 0
            _ = speechTracker.reset()
            if playerAttached {
                playerNode.pause()
            }
            continuation.yield(.interruptedBySystem)
        case .ended(let shouldResume):
            // Only resume the speech session when iOS says we may. Do not
            // `playerNode.play()` — `interruptedBySystem` already asked the
            // machine to stop playback, and resume lands in `waitingUser`.
            //
            // Saying nothing when iOS withholds resume was a trap, not caution.
            // `.began` parked the machine in its suspended phase, and a
            // suspended machine discards every event but five — so with no
            // `.systemInterruptEnded` and no failure, nothing on any path could
            // lift the suspension. Ending it is the honest outcome: `.failed` is
            // one of the five events that still land, and it reaches the user as
            // a retryable error instead of a freeze.
            guard shouldResume else {
                continuation.yield(.failed("音频被系统中断，本轮练习已停止"))
                return
            }
            isSystemInterrupted = false
            // Before the lift, so the count is attributed to the interruption
            // that just ended rather than to whatever comes next.
            continuation.yield(.captureInterruptionLifted(droppedBuffers: interruptionDroppedBuffers))
            continuation.yield(.systemInterruptEnded)
        case .routeChanged(let reason):
            continuation.yield(.routeChanged(reason))
        }
    }
}
