import Foundation

/// Client-side terminal status of one user speaking turn (I20 T-I20-2).
///
/// Distinct from `WSControlFrame.TurnOutcome` on `ai.turn.end` (S→C, includes
/// `partial`). This enum is what the session machine records and, when the
/// utterance is still open, what `client.turn.abort` carries (C→S).
///
/// `ok` is never sent as abort — that path uses `user.speech.end`.
public enum TurnOutcome: String, Equatable, Sendable, Codable {
    case ok
    case timeout
    case userAbandoned = "user_abandoned"
    case error
}
