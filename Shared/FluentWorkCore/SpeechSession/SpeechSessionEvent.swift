import Foundation

/// Domain events for the SpeechSession machine (tech design §2.2).
///
/// `badgeHit` is intentionally absent — feedback badges bypass this machine and
/// dispatch display actions directly.
public enum SpeechSessionEvent: Equatable, Sendable {
    case sessionStartTap
    case socketReady
    case aiTurnEnd
    case vadSpeechStart
    case holdStart
    case vadSpeechEnd(turnID: String?)
    case holdEnd(turnID: String?)
    /// B14: Server-side ASR transcript relayed from the voice provider via WSS.
    /// This is the authoritative transcript for this turn. When received, the
    /// middleware immediately calls `sendSpeechBoundary(text:)` so the backend
    /// can perform badge hit detection using the confirmed server-side text.
    case serverASRReceived(text: String, turnID: String?)
    case aiFirstAudioChunk
    /// Soft degrade (e.g. transport already left the voice path) → immediate `degradedText`.
    case networkDegraded
    /// Hard disconnect → 3s reconnect window; timeout → `degradedText` (§2.2).
    case networkLost
    case reconnectTimedOut
    case reconnectSucceeded
    case interruptedBySystem
    case systemInterruptEnded
    case textMessageSent
    case textReplyReceived
    case endTap
    case failed(String)
}
