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
            case .systemInterruptEnded, .endTap, .forceClose, .failed:
                break
            default:
                return []
            }
        }

        let from = state.phase
        var effects: [SpeechSessionSideEffect] = []

        switch (state.phase, event) {
        case (.idle, .sessionStartTap):
            state.phase = .connecting
            state.failureReason = nil
            state.isReconnecting = false
            state.suspendedPhase = nil
            state.processingSubStage = nil
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
             (.processingReview, .aiTurnEnd),
             (.aiSpeaking, .aiTurnEnd):
            state.phase = .waitingUser
            state.processingSubStage = nil

        case (.aiSpeaking, .vadSpeechStart), (.aiSpeaking, .holdStart):
            state.phase = .recording
            state.processingSubStage = nil
            effects.append(contentsOf: [.stopPlayback, .sendInterrupt])

        case (.waitingUser, .vadSpeechStart), (.waitingUser, .holdStart):
            state.phase = .recording
            state.processingSubStage = nil

        case (.recording, .vadSpeechEnd), (.recording, .holdEnd):
            state.phase = .processingASR
            state.processingSubStage = .asr
            state.userTurnCount += 1

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
             (.processingReview, .socketReady), (.degradedText, .socketReady):
            state.isReconnecting = false

        default:
            return []
        }

        if state.phase != from {
            effects.insert(.trackTransition(from: from, to: state.phase), at: 0)
        }

        return effects
    }

    private static func isActive(_ phase: SpeechSessionPhase) -> Bool {
        phase.isActive
    }
}
