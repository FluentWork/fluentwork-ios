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
    /// Hold TTS without dumping the queue. Cancel of 结束练习 must be able to continue.
    case pausePlayback
    /// Release a `.pausePlayback` hold.
    case resumePlayback
    case startReconnectWindow
    /// B15: turn-level timeout fired (backend 60s collectTurn expired).
    /// Middleware cancels the transport task and ends the session.
    case turnTimeoutExpired
    case endSession
    case sendTextMessage
    /// Immediate background-safe teardown (stop capture, session.end, close transport).
    case forceClose
    /// A phase change, or an advance within `.processing`.
    ///
    /// `stage` is the resulting pipeline position, `nil` outside `.processing`.
    /// It is carried here because after the three processing phases merged,
    /// an ASR → LLM advance is **not a phase change** — `from == to` — and a
    /// telemetry stream that stopped at "entered processing" would make a
    /// stage that never runs look identical to one that ran silently. That is
    /// precisely the failure shape `P1-15` records.
    case trackTransition(
        from: SpeechSessionPhase,
        to: SpeechSessionPhase,
        stage: ProcessingStage?
    )
}
