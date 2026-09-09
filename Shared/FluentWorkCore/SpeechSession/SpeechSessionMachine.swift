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
            state.processingSubStage = nil
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
            state.processingSubStage = nil
            effects.append(.endSession)

        case (.processingASR, .aiTurnEnd),
             (.processingLLM, .aiTurnEnd),
             (.processingReview, .aiTurnEnd):
            state.phase = .waitingForEvaluation
            state.processingSubStage = nil

        case (.aiSpeaking, .aiTurnEnd) where state.userTurnCount > 0:
            state.phase = .waitingForEvaluation
            state.processingSubStage = nil

        case (.aiSpeaking, .aiTurnEnd):
            // Greeting / bootstrap turn (DevEcho and Volc Start() send
            // ai.turn.end before the user has spoken). Land in waitingUser.
            state.phase = .waitingUser
            state.processingSubStage = nil

        case (.waitingForEvaluation, .evaluationReceived):
            state.phase = .waitingUser
            state.processingSubStage = nil

        case (.aiSpeaking, .vadSpeechStart), (.aiSpeaking, .holdStart):
            state.phase = .recording
            state.processingSubStage = nil
            effects.append(contentsOf: [.stopPlayback, .sendInterrupt])

        case (.waitingUser, .vadSpeechStart), (.waitingUser, .holdStart),
             (.waitingForAIAnswer, .vadSpeechStart), (.waitingForAIAnswer, .holdStart),
             (.waitingForEvaluation, .vadSpeechStart), (.waitingForEvaluation, .holdStart):
            state.phase = .recording
            state.processingSubStage = nil

        case (.recording, .vadSpeechEnd), (.recording, .holdEnd):
            state.phase = .processingASR
            state.processingSubStage = .asr
            state.userTurnCount += 1
            state.lastTurnOutcome = .ok

        case (.recording, .recordingTimedOut):
            // I20 T-I20-1: user still recording after 60s. Abort this turn, keep
            // the session. Do not enter processingASR (that would arm B15's 70s
            // collectTurn fallback) and do not emit user.speech.end.
            // I21: land in waitingForAIAnswer, not waitingUser.
            state.phase = .waitingForAIAnswer
            effects.append(abortOpenRecording(&state, outcome: .timeout))

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

        case (.processingASR, .serverASRReceived),
             (.processingASR, .processingSubStageReached(.llm)):
            state.phase = .processingLLM
            state.processingSubStage = .llm

        case (.processingLLM, .processingSubStageReached(.review)):
            state.phase = .processingReview
            state.processingSubStage = .review

        case (.processingASR, .aiFirstAudioChunk),
             (.processingLLM, .aiFirstAudioChunk),
             (.processingReview, .aiFirstAudioChunk):
            state.phase = .aiSpeaking
            state.processingSubStage = nil

        case (.degradedText, .textMessageSent):
            // User text → POST /messages (middleware interprets `.sendTextMessage`).
            effects.append(.sendTextMessage)

        case (.degradedText, .textReplyReceived):
            // AI reply is display-only; transcript/UI updates stay outside this machine.
            break

        case (_, .networkDegraded) where isActive(state.phase):
            state.phase = .degradedText
            state.isReconnecting = false
            state.processingSubStage = nil

        case (_, .networkLost) where isActive(state.phase):
            state.isReconnecting = true
            effects.append(.startReconnectWindow)

        case (_, .reconnectSucceeded) where state.isReconnecting:
            state.isReconnecting = false
            if state.phase == .connecting {
                state.phase = .aiSpeaking
            }

        case (_, .reconnectTimedOut) where state.isReconnecting || isActive(state.phase):
            state.isReconnecting = false
            if state.phase != .failed, state.phase != .ended {
                state.phase = .degradedText
                state.processingSubStage = nil
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
                state.processingSubStage = nil
            }
            state.suspendedPhase = nil

        case (_, .forceClose) where state.phase.isActive:
            state.phase = .ended
            state.isReconnecting = false
            state.suspendedPhase = nil
            state.processingSubStage = nil
            effects.append(.forceClose)

        case (_, .endTap) where state.phase != .idle && state.phase != .ended:
            state.phase = .ended
            state.isReconnecting = false
            state.suspendedPhase = nil
            state.processingSubStage = nil
            effects.append(.endSession)

        case (_, .failed(let message)) where state.phase != .ended:
            state.phase = .failed
            state.failureReason = message
            state.isReconnecting = false
            state.suspendedPhase = nil
            state.processingSubStage = nil
            effects.append(.endSession)

        // Idempotent: duplicate socketReady while connecting/reconnecting after first ready.
        case (.aiSpeaking, .socketReady), (.waitingUser, .socketReady), (.recording, .socketReady),
             (.processingASR, .socketReady), (.processingLLM, .socketReady),
             (.processingReview, .socketReady), (.waitingForAIAnswer, .socketReady),
             (.waitingForEvaluation, .socketReady), (.degradedText, .socketReady):
            state.isReconnecting = false

        default:
            return []
        }

        if state.phase != from {
            guard isValidTransition(from: from, to: state.phase) else {
                state = snapshot
                return []
            }
            effects.insert(.trackTransition(from: from, to: state.phase), at: 0)
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
             (.waitingForAIAnswer, .recording),
             (.waitingForEvaluation, .recording),
             (.recording, .processingASR),
             (.recording, .waitingForAIAnswer),
             (.recording, .waitingUser),
             (.processingASR, .processingLLM),
             (.processingASR, .aiSpeaking),
             (.processingLLM, .processingReview),
             (.processingLLM, .aiSpeaking),
             (.processingReview, .aiSpeaking),
             (.processingASR, .waitingForEvaluation),
             (.processingLLM, .waitingForEvaluation),
             (.processingReview, .waitingForEvaluation),
             (.aiSpeaking, .waitingForEvaluation),
             (.waitingForEvaluation, .waitingUser),
             (.waitingForAIAnswer, .waitingUser),
             (.aiSpeaking, .waitingUser),
             (.processingASR, .waitingUser),
             (.processingLLM, .waitingUser),
             (.processingReview, .waitingUser):
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

    /// Consume the open recording turn and emit `client.turn.abort`.
    /// Caller sets the destination phase and any extra effects.
    private static func abortOpenRecording(
        _ state: inout SpeechSessionState,
        outcome: TurnOutcome
    ) -> SpeechSessionSideEffect {
        state.userTurnCount += 1
        state.lastTurnOutcome = outcome
        state.processingSubStage = nil
        return .sendTurnAbort(
            turnID: "turn-\(state.userTurnCount)",
            outcome: outcome
        )
    }
}
