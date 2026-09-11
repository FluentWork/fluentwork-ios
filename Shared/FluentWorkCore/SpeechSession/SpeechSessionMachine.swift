import Foundation

/// Pure SpeechSession reduce: `(inout State, Event) -> [SideEffect]`.
///
/// Zero IO. Illegal combinations are no-ops (state unchanged, no effects).
/// Wiring lives in Middleware; do not call AudioEngine / Transport from here.
public enum SpeechSessionMachine {
    @discardableResult
    public static func reduce(
        _ state: inout SpeechSessionState,
        event: SpeechSessionEvent
    ) -> [SpeechSessionSideEffect] {
        // While system-interrupted, ignore active session events so VAD/audio/network
        // cannot drive the machine under a stale live phase (§2.2 interruptedBySystem).
        if state.suspendedPhase != nil {
            switch event {
            case .systemInterruptEnded, .endTap, .forceClose, .failed, .recordingTimedOut:
                break
            default:
                return []
            }
        }

        let from = state.phase
        let snapshot = state
        var effects: [SpeechSessionSideEffect] = []

        switch (state.phase, event) {
        case (.idle, .sessionStartTap):
            state.phase = .connecting
            state.failureReason = nil
            state.isReconnecting = false
            state.suspendedPhase = nil
            state.processingStage = nil
            state.lastTurnOutcome = nil
            effects.append(.createSession)

        case (.connecting, .socketReady):
            state.phase = .aiSpeaking
            state.isReconnecting = false

        case (.connecting, .failed(let message)):
            state.phase = .failed
            state.failureReason = message
            state.isReconnecting = false
            state.suspendedPhase = nil
            state.processingStage = nil
            effects.append(.endSession)

        // The turn is done; the backend scorer is what has not answered. That
        // is a stage, not a phase — giving it a phase is what let a 20s budget
        // become user-visible behaviour (F19).
        case (.processing, .aiTurnEnd):
            state.processingStage = .evaluation

        case (.aiSpeaking, .aiTurnEnd) where state.userTurnCount > 0:
            state.phase = .processing
            state.processingStage = .evaluation

        case (.aiSpeaking, .aiTurnEnd):
            // Greeting / bootstrap turn (DevEcho and Volc Start() send
            // ai.turn.end before the user has spoken). Land in waitingUser.
            state.phase = .waitingUser
            state.processingStage = nil

        case (.processing, .evaluationReceived) where state.processingStage == .evaluation:
            state.phase = .waitingUser
            state.processingStage = nil

        case (.processing, .evaluationTimedOut) where state.processingStage == .evaluation:
            // Badge never arrived. Keep the session; end the turn.
            //
            // No `.stopPlayback` here. "Leftover TTS is dropped" was the old
            // reasoning, and it assumed the audio had finished — but the timer
            // and the audio are unrelated clocks. Speech arrives as one burst at
            // turn end and takes as long to play as the reply is long, while
            // `evaluationWait` is a fixed 20s, so every reply longer than that
            // lost its tail: measured on device, 276 frames (27.6s of audio)
            // delivered in 88ms and playback stopped 20.6s later.
            //
            // Nothing needs the timer for silence. A badge that arrives in time
            // lands in this same phase without stopping playback, and barge-in
            // stops it on both paths that mean it — from `.aiSpeaking` and from
            // this phase, both via `vadSpeechStart` / `holdStart`.
            state.phase = .waitingUser
            state.processingStage = nil

        case (.aiSpeaking, .vadSpeechStart), (.aiSpeaking, .holdStart):
            state.phase = .recording
            state.processingStage = nil
            effects.append(contentsOf: [.stopPlayback, .sendInterrupt])

        // `aiAnswer` (I21's abort landing pad) starts a new turn exactly like
        // `waitingUser` does — nothing is playing, so nothing needs stopping.
        case (.waitingUser, .vadSpeechStart), (.waitingUser, .holdStart),
             (.processing, .vadSpeechStart) where state.processingStage == .aiAnswer,
             (.processing, .holdStart) where state.processingStage == .aiAnswer:
            state.phase = .recording
            state.processingStage = nil

        // The evaluation stage is different: the reply may still be playing,
        // and this path is one of the two that mean barge-in.
        case (.processing, .vadSpeechStart) where state.processingStage == .evaluation,
             (.processing, .holdStart) where state.processingStage == .evaluation:
            // Next utterance may overlap leftover TTS after ai.turn.end.
            state.phase = .recording
            state.processingStage = nil
            effects.append(.stopPlayback)

        case (.recording, .vadSpeechEnd), (.recording, .holdEnd):
            state.phase = .processing
            state.processingStage = .asr
            state.userTurnCount += 1
            state.lastTurnOutcome = .ok

        case (.recording, .recordingTimedOut):
            // I20 T-I20-1: user still recording after 60s. Abort this turn, keep
            // the session. Do not enter .processing (that would arm B15's 70s
            // collectTurn fallback) and do not emit user.speech.end.
            // I21: land in the `aiAnswer` stage, not `waitingUser` — the
            // aborted turn's answer is still coming.
            //
            // Abort *before* setting the destination: `abortOpenRecording`
            // clears the stage (it ends a turn), so setting it first would be
            // overwritten and the landing pad would silently read as "no
            // stage" — the drift the invariant guard exists to catch.
            effects.append(abortOpenRecording(&state, outcome: .timeout))
            state.phase = .processing
            state.processingStage = .aiAnswer

        // Recording-specific terminals before the catch-alls: an open utterance
        // must not look like `user.speech.end` / outcome=ok.
        case (.recording, .endTap):
            effects.append(abortOpenRecording(&state, outcome: .userAbandoned))
            state.phase = .ended
            state.isReconnecting = false
            state.suspendedPhase = nil
            effects.append(.endSession)

        case (.recording, .forceClose):
            effects.append(abortOpenRecording(&state, outcome: .userAbandoned))
            state.phase = .ended
            state.isReconnecting = false
            state.suspendedPhase = nil
            effects.append(.forceClose)

        case (.recording, .failed(let message)):
            effects.append(abortOpenRecording(&state, outcome: .error))
            state.phase = .failed
            state.failureReason = message
            state.isReconnecting = false
            state.suspendedPhase = nil
            effects.append(.endSession)

        case (.recording, .networkLost):
            effects.append(abortOpenRecording(&state, outcome: .error))
            state.phase = .waitingUser
            state.isReconnecting = true
            effects.append(.startReconnectWindow)

        case (.recording, .networkDegraded):
            effects.append(abortOpenRecording(&state, outcome: .error))
            state.phase = .degradedText
            state.isReconnecting = false

        // The backend pipeline advancing inside `.processing`. A `where` guard
        // keeps the hop legal from the stage it is legal from: the phase alone
        // can no longer say where we are.
        case (.processing, .serverASRReceived) where state.processingStage == .asr,
             (.processing, .processingStageReached(.llm)) where state.processingStage == .asr:
            state.processingStage = .llm

        case (.processing, .processingStageReached(.review)) where state.processingStage == .llm:
            state.processingStage = .review

        case (.processing, .aiFirstAudioChunk):
            state.phase = .aiSpeaking
            state.processingStage = nil

        case (.degradedText, .textMessageSent):
            // User text → POST /messages (middleware interprets `.sendTextMessage`).
            effects.append(.sendTextMessage)

        case (.degradedText, .textReplyReceived):
            // AI reply is display-only; transcript/UI updates stay outside this machine.
            break

        case (_, .networkDegraded) where isActive(state.phase):
            state.phase = .degradedText
            state.isReconnecting = false
            state.processingStage = nil

        case (_, .networkLost) where isActive(state.phase):
            state.isReconnecting = true
            effects.append(.startReconnectWindow)
            if state.discardsTurnOnReconnect {
                effects.append(.stopPlayback)
            }

        case (_, .reconnectSucceeded) where state.isReconnecting:
            effects.append(contentsOf: completeReconnect(&state))

        case (_, .reconnectTimedOut) where state.isReconnecting || isActive(state.phase):
            state.isReconnecting = false
            if state.phase != .failed, state.phase != .ended {
                state.phase = .degradedText
                state.processingStage = nil
            }

        case (_, .interruptedBySystem) where isActive(state.phase) && state.suspendedPhase == nil:
            state.suspendedPhase = state.phase
            effects.append(.stopPlayback)

        case (_, .systemInterruptEnded) where state.suspendedPhase != nil:
            // Voice-path suspend resumes to waitingUser (§2.2). Preserve
            // connecting / degradedText so interrupt cannot skip handshake or
            // promote out of text degrade.
            switch state.suspendedPhase {
            case .connecting, .degradedText:
                state.phase = state.suspendedPhase!
            default:
                state.phase = .waitingUser
                state.processingStage = nil
            }
            state.suspendedPhase = nil

        case (_, .forceClose) where state.phase.isActive:
            state.phase = .ended
            state.isReconnecting = false
            state.suspendedPhase = nil
            state.processingStage = nil
            effects.append(.forceClose)

        case (_, .endTap) where state.phase != .idle && state.phase != .ended:
            state.phase = .ended
            state.isReconnecting = false
            state.suspendedPhase = nil
            state.processingStage = nil
            effects.append(.endSession)

        case (_, .failed(let message)) where state.phase != .ended:
            state.phase = .failed
            state.failureReason = message
            state.isReconnecting = false
            state.suspendedPhase = nil
            state.processingStage = nil
            effects.append(.endSession)

        // Production reconnect: transport maps `.connected` to `.socketReady`,
        // not `.reconnectSucceeded`. In-flight turns cannot be replayed.
        case (_, .socketReady) where state.isReconnecting:
            effects.append(contentsOf: completeReconnect(&state))

        // Idempotent: duplicate socketReady while already live.
        case (.aiSpeaking, .socketReady), (.waitingUser, .socketReady), (.recording, .socketReady),
             (.processing, .socketReady), (.degradedText, .socketReady):
            state.isReconnecting = false

        default:
            return []
        }

        if state.phase != from {
            guard isValidTransition(from: from, to: state.phase) else {
                state = snapshot
                return []
            }
            effects.insert(
                .trackTransition(from: from, to: state.phase, stage: state.processingStage),
                at: 0
            )
        } else if state.processingStage != snapshot.processingStage {
            // The backend pipeline advanced without a phase change. Before the
            // merge each hop *was* a phase change and `trackTransition` carried
            // it; afterwards an ASR → LLM advance would emit nothing at all,
            // and a pipeline step that silently stops running is
            // indistinguishable from one that never runs. `from == to` is the
            // signal that this is a stage advance — read `stage` for what moved.
            effects.insert(
                .trackTransition(from: .processing, to: .processing, stage: state.processingStage),
                at: 0
            )
        }

        return effects
    }

    /// Allow-list for phase hops. The ticket's 5-state graph is mapped onto
    /// the live 13-phase machine; illegal hops stay no-ops.
    public static func isValidTransition(
        from old: SpeechSessionPhase,
        to new: SpeechSessionPhase
    ) -> Bool {
        if old == new { return false }
        switch (old, new) {
        case (.idle, .connecting),
             (.connecting, .aiSpeaking),
             (.aiSpeaking, .recording),
             (.waitingUser, .recording),
             (.processing, .recording),
             (.recording, .processing),
             (.aiSpeaking, .processing),
             (.recording, .waitingUser),
             (.processing, .aiSpeaking),
             (.aiSpeaking, .waitingUser),
             (.processing, .waitingUser):
            return true
        case (_, .ended) where old.isActive:
            return true
        case (_, .failed) where old != .ended:
            return true
        case (_, .degradedText) where old.isActive:
            return true
        default:
            return false
        }
    }

    private static func isActive(_ phase: SpeechSessionPhase) -> Bool {
        phase.isActive
    }

    /// Socket came back. Connecting finishes handshake; an in-flight AI turn
    /// is discarded (no PCM replay) and the user can speak again.
    private static func completeReconnect(
        _ state: inout SpeechSessionState
    ) -> [SpeechSessionSideEffect] {
        state.isReconnecting = false
        if state.phase == .connecting {
            state.phase = .aiSpeaking
            return []
        }
        guard state.discardsTurnOnReconnect else { return [] }
        state.phase = .waitingUser
        state.processingStage = nil
        return [.stopPlayback]
    }

    /// Consume the open recording turn and emit `client.turn.abort`.
    /// Caller sets the destination phase and any extra effects.
    private static func abortOpenRecording(
        _ state: inout SpeechSessionState,
        outcome: TurnOutcome
    ) -> SpeechSessionSideEffect {
        state.userTurnCount += 1
        state.lastTurnOutcome = outcome
        state.processingStage = nil
        return .sendTurnAbort(
            turnID: "turn-\(state.userTurnCount)",
            outcome: outcome
        )
    }
}
