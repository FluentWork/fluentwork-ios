import Foundation

/// Side effects emitted by the pure SpeechSession machine.
/// Interpreted only by SpeechSession Middleware — never executed inside reduce.
public enum SpeechSessionSideEffect: Equatable, Sendable {
    case createSession
    case sendInterrupt
    case stopPlayback
    case startReconnectWindow
    case endSession
    case sendTextMessage
    case trackTransition(from: SpeechSessionPhase, to: SpeechSessionPhase)
}
