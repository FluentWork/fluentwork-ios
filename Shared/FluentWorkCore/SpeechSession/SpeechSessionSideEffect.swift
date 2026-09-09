import Foundation

/// Side effects emitted by the pure SpeechSession machine.
/// Interpreted only by SpeechSession Middleware — never executed inside reduce.
public enum SpeechSessionSideEffect: Equatable, Sendable {
    case createSession
    case sendInterrupt
    /// I20 T-I20-1: send `client.turn.abort` for an in-progress recording turn.
    /// Does not end the session and must not be folded into `.turnTimeoutExpired`.
    case sendTurnAbort(turnID: String, outcome: TurnOutcome)
    case stopPlayback
    case startReconnectWindow
    /// B15: turn-level timeout fired (backend 60s collectTurn expired).
    /// Middleware cancels the transport task and ends the session.
    case turnTimeoutExpired
    case endSession
    case sendTextMessage
    /// Immediate background-safe teardown (stop capture, session.end, close transport).
    case forceClose
    case trackTransition(from: SpeechSessionPhase, to: SpeechSessionPhase)
}
