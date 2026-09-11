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
    /// I20 T-I20-1: 60s cap while `.recording`. Not B15's 70s processing cap.
    /// Machine enters `.waitingForAIAnswer` (abort landing pad, not “wait for AI”)
    /// and emits `.sendTurnAbort` — session stays alive.
    case recordingTimedOut
    /// B14: Server-side ASR transcript relayed from the voice provider via WSS.
    /// This is the authoritative transcript for this turn. When received, the
    /// middleware immediately calls `sendSpeechBoundary(text:)` so the backend
    /// can perform badge hit detection using the confirmed server-side text.
    case serverASRReceived(text: String, turnID: String?)
    /// Advances the pipeline inside `.processing` — ASR → LLM, or LLM → review —
    /// when no dedicated protocol event exists for that hop (review has none).
    /// Prefer `.serverASRReceived` for the ASR → LLM hop.
    ///
    /// This is **not** a phase change: `.processing` is one product state.
    case processingStageReached(ProcessingStage)
    case aiFirstAudioChunk
    /// Turn-level feedback landed (`feedback.badge`). Leaves `.waitingForEvaluation`.
    /// Full session review is REST (I16), not a WSS eval.frame.
    case evaluationReceived
    /// Watchdog: no badge within the evaluation wait. Leaves `.waitingForEvaluation`
    /// to `.waitingUser`. Does **not** fail the session and is not B15.
    case evaluationTimedOut
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
    /// Immediate teardown; middleware must not wait on network replies.
    case forceClose
}
