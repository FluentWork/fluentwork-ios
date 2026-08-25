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
    /// Phase captured when `interruptedBySystem` suspends the session.
    public var suspendedPhase: SpeechSessionPhase?
    public var isReconnecting: Bool
    public var failureReason: String?

    public init(
        phase: SpeechSessionPhase = .idle,
        suspendedPhase: SpeechSessionPhase? = nil,
        isReconnecting: Bool = false,
        failureReason: String? = nil
    ) {
        self.phase = phase
        self.suspendedPhase = suspendedPhase
        self.isReconnecting = isReconnecting
        self.failureReason = failureReason
    }

    public static let initial = SpeechSessionState()
}
