import Foundation

/// Side effects emitted by the pure SpeechSession machine.
/// Interpreted only by SpeechSession Middleware — never executed inside reduce.
public enum SpeechSessionSideEffect: Equatable, Sendable {
    case createSession
    case sendInterrupt
    case stopPlayback
    case startReconnectWindow
    /// B15: turn-level timeout fired (backend 60s collectTurn expired).
    /// Middleware cancels the transport task and ends the session.
    case turnTimeoutExpired
    case endSession
    case sendTextMessage
    case trackTransition(from: SpeechSessionPhase, to: SpeechSessionPhase)
}
