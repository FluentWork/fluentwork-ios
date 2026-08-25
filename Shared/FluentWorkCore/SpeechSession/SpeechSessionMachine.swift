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
            case .systemInterruptEnded, .endTap, .failed:
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
            effects.append(.createSession)

        case (.connecting, .socketReady):
            state.phase = .aiSpeaking
            state.isReconnecting = false

        case (.connecting, .failed(let message)):
            state.phase = .failed
            state.failureReason = message

        case (.aiSpeaking, .aiAudioEnd):
            state.phase = .waitingUser

        case (.aiSpeaking, .vadSpeechStart), (.aiSpeaking, .holdStart):
            state.phase = .recording
            effects.append(contentsOf: [.stopPlayback, .sendInterrupt])

        case (.waitingUser, .vadSpeechStart), (.waitingUser, .holdStart):
            state.phase = .recording

        case (.recording, .vadSpeechEnd), (.recording, .holdEnd):
            state.phase = .processing

        case (.processing, .aiFirstAudioChunk):
            state.phase = .aiSpeaking

        case (.degradedText, .textMessageSent):
            break

        case (.degradedText, .textReplyReceived):
            effects.append(.sendTextMessage)

        case (_, .networkDegraded) where isActive(state.phase):
            state.phase = .degradedText
            state.isReconnecting = false

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
            }

        case (_, .interruptedBySystem) where isActive(state.phase) && state.suspendedPhase == nil:
            state.suspendedPhase = state.phase
            effects.append(.stopPlayback)

        case (_, .systemInterruptEnded) where state.suspendedPhase != nil:
            // Resume only from an active suspend; always land on waitingUser (§2.2).
            state.phase = .waitingUser
            state.suspendedPhase = nil

        case (_, .endTap) where state.phase != .idle && state.phase != .ended:
            state.phase = .ended
            state.isReconnecting = false
            state.suspendedPhase = nil
            effects.append(.endSession)

        case (_, .failed(let message)) where state.phase != .ended:
            state.phase = .failed
            state.failureReason = message
            state.isReconnecting = false
            state.suspendedPhase = nil

        // Idempotent: duplicate socketReady while connecting/reconnecting after first ready.
        case (.aiSpeaking, .socketReady), (.waitingUser, .socketReady), (.recording, .socketReady),
             (.processing, .socketReady), (.degradedText, .socketReady):
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
        switch phase {
        case .idle, .ended, .failed:
            return false
        case .connecting, .aiSpeaking, .waitingUser, .recording, .processing, .degradedText:
            return true
        }
    }
}
