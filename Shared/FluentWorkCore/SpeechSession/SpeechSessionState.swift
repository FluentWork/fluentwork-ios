import Foundation

/// Speaking-room session phases from iOS tech design §2.1.
///
/// This file is the frozen SpeechSession contract surface. Replace the pure
/// machine implementation in `SpeechSessionMachine.swift` if ownership moves,
/// but keep these types stable for Store / Middleware wiring.
public enum SpeechSessionPhase: String, Equatable, Sendable {
    case idle
    case connecting
    case aiSpeaking
    case waitingUser
    case recording
    case processing
    case degradedText
    case ended
    case failed
}

public struct SpeechSessionState: Equatable, Sendable {
    public var phase: SpeechSessionPhase
    /// Non-nil while system-interrupted: machine ignores active events until
    /// `systemInterruptEnded` (or end/fail). Captures the phase at suspend time.
    public var suspendedPhase: SpeechSessionPhase?
    public var isReconnecting: Bool
    public var failureReason: String?
    /// Incremented each time the machine enters `.processing` from `.recording`,
    /// i.e. once per user speaking turn. Used to populate `user.speech.end`'s
    /// `turn_id` field so the backend can dedupe badge hits per-turn.
    public var userTurnCount: Int

    public init(
        phase: SpeechSessionPhase = .idle,
        suspendedPhase: SpeechSessionPhase? = nil,
        isReconnecting: Bool = false,
        failureReason: String? = nil,
        userTurnCount: Int = 0
    ) {
        self.phase = phase
        self.suspendedPhase = suspendedPhase
        self.isReconnecting = isReconnecting
        self.failureReason = failureReason
        self.userTurnCount = userTurnCount
    }

    public static let initial = SpeechSessionState()
}
