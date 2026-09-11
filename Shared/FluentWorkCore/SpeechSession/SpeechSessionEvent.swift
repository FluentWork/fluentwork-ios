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
    /// **No producer, and none is possible from this side.**
    ///
    /// Who dispatches this? Nobody. Production maps the transport's
    /// `.stateChanged(.connected)` to `.socketReady`, and `.socketReady` is what
    /// the machine's reconnect branch actually handles — so the working path
    /// exists, it just has no way to be entered: **nothing re-opens the socket.**
    ///
    /// The three-second window does not try. It sleeps, then dispatches
    /// `.reconnectTimedOut`. Every network loss lands in `degradedText`, with no
    /// exception.
    ///
    /// Wiring this is not a client-side change. The gateway cannot resume a
    /// session: `auth` carries a one-time ticket and no session id, the gateway
    /// mints its own `session_id`, per-session state lives in a struct discarded
    /// on disconnect, and there is no session registry. It would need a new
    /// frame carrying a session id (or a reusable ticket), a lookup that
    /// survives gateway restarts, and persisted live context. See `docs/55`.
    ///
    /// Kept rather than deleted so the shape stays visible — `88_` §⑧ names this
    /// and `processingReview` as the two instances of "定义在、消费分支在、测试在,
    /// 唯独触发者不在", and `networkLossDegradesAndNeverAttemptsAReconnect` pins
    /// it so it cannot go back to looking alive.
    case reconnectSucceeded
    case interruptedBySystem
    case systemInterruptEnded
    case textMessageSent
    case textReplyReceived
    /// Confirmation for 结束练习 is on screen. Pause TTS; do not end the session.
    case endSessionConfirmShown
    /// User cancelled 结束练习. Resume TTS from the pause point.
    case endSessionConfirmCancelled
    case endTap
    case failed(String)
    /// Immediate teardown; middleware must not wait on network replies.
    case forceClose
}
