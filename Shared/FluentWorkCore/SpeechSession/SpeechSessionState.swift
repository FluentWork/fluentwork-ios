import Foundation

/// Speaking-room session phases from iOS tech design §2.1.
///
/// This file is the frozen SpeechSession contract surface. Replace the pure
/// machine implementation in `SpeechSessionMachine.swift` if ownership moves,
/// but keep these types stable for Store / Middleware wiring.
public enum SpeechSessionPhase: String, Equatable, Sendable, CaseIterable {
    case idle
    case connecting
    case aiSpeaking
    case waitingUser
    case recording
    /// The system is working on the turn the user just finished.
    ///
    /// **One product state.** The user does not have three of these; the
    /// difference between "running ASR" and "running the review pass" is where
    /// the *backend pipeline* is, and that lives in
    /// `SpeechSessionState.processingStage`. Encoding pipeline position as
    /// phase made a backend timer into user-visible behaviour (F19) and made
    /// every phase-enumerating list a place to forget one (F20, F17).
    case processing
    case waitingForAIAnswer
    case waitingForEvaluation
    case degradedText
    case ended
    case failed

    /// Maps the iOS-side phase to the backend's `stage` log tag so the iOS
    /// `timing_phase_transition` log lines up with the backend's
    /// `voice user speech frame`, `voice session ready`, and `session.end
    /// persisted` events when they share the same session id. Mirrors the
    /// voice-gateway handler's `stage` field on
    /// `voiceproto.ProviderOutbound.Control` payloads.
    /// Phase-only fallback. **Prefer `SpeechSessionState.stageTag`.**
    ///
    /// `.processing` cannot answer this alone: the stage is what distinguishes
    /// the backend's pipeline positions, and only the state holds it. This
    /// returns the un-staged `"processing"` so a phase in isolation still has
    /// an honest answer rather than a guess.
    public var stageTag: String {
        switch self {
        case .idle:                    return "idle"
        case .connecting:              return "orchestration"
        case .aiSpeaking:              return "tts"
        case .waitingUser:             return "waiting_user"
        case .recording:               return "vad_capture"
        case .processing:              return "processing"
        case .waitingForAIAnswer:      return "waiting_for_ai_answer"
        case .waitingForEvaluation:    return "waiting_for_evaluation"
        case .degradedText:            return "text_fallback"
        case .ended:                   return "ended"
        case .failed:                  return "failed"
        }
    }

    /// Tracker / log label. Distinct from `rawValue` so new V2.0 waits stay snake_case.
    public var label: String { stageTag }

    /// Live speaking-room phases that still own capture/transport.
    /// Matches `SpeechSessionMachine` — idle / ended / failed are terminal.
    public var isActive: Bool {
        switch self {
        case .idle, .ended, .failed:
            return false
        case .connecting, .aiSpeaking, .waitingUser, .recording,
             .processing, .waitingForAIAnswer, .waitingForEvaluation, .degradedText:
            return true
        }
    }

    /// True while the machine is processing the user's last turn.
    public var isProcessing: Bool { self == .processing }

    /// In-flight AI turn cannot be recovered after the socket comes back.
    /// PCM is not replayed; land in `.waitingUser`.
    public var discardsTurnOnReconnect: Bool {
        switch self {
        case .processing, .aiSpeaking, .waitingForEvaluation:
            return true
        case .idle, .connecting, .waitingUser, .recording,
             .waitingForAIAnswer, .degradedText, .ended, .failed:
            return false
        }
    }
}

/// Where the **backend pipeline** is, while the phase is `.processing`.
///
/// Not a product state: the user's experience of all of these is "it is
/// working on my sentence". Kept as data rather than as phases so that
/// enumerating phases no longer means enumerating pipeline internals — which
/// is how F20 (a phase with no timer) and F19 (a timer that stopped playback)
/// happened.
public enum ProcessingStage: String, Equatable, Sendable, Codable, CaseIterable {
    /// Backend is transcribing.
    case asr
    /// Transcript is with the model.
    case llm
    /// Review / scoring pass.
    case review

    /// The cross-service log tag. Preserves the exact strings the merged
    /// phases used to emit, so backend log correlation is unchanged.
    public var stageTag: String { rawValue }
}

public struct SpeechSessionState: Equatable, Sendable {
    public var phase: SpeechSessionPhase
    /// Non-nil while system-interrupted: machine ignores active events until
    /// `systemInterruptEnded` (or end/fail). Captures the phase at suspend time.
    public var suspendedPhase: SpeechSessionPhase?
    public var isReconnecting: Bool
    public var failureReason: String?
    /// Incremented each time a recording turn reaches a terminal outcome
    /// (normal `user.speech.end`, abort, abandon, or error). Used to populate
    /// `user.speech.end` / `client.turn.abort` `turn_id` so the backend can
    /// dedupe badge hits per-turn.
    public var userTurnCount: Int
    /// Last completed user-turn outcome. `nil` until a recording turn ends.
    /// Distinct from `WSControlFrame.TurnOutcome` on `ai.turn.end`.
    public var lastTurnOutcome: TurnOutcome?
    /// Where the backend pipeline is. **Non-nil exactly when `phase == .processing`.**
    ///
    /// This used to be a *derived* shadow of the phase, with the phase as
    /// master. The relationship is now inverted: the stage is the data and the
    /// phase is the product state, because "which pipeline step is running" is
    /// not something the user has a state for.
    ///
    /// The invariant is maintained by the construction points in
    /// `SpeechSessionMachine` and pinned by
    /// `processingStageIsNonNilExactlyWhileProcessing`.
    public var processingStage: ProcessingStage?

    /// The cross-service log tag, resolved with the pipeline stage.
    ///
    /// `.processing` alone cannot answer this — `asr` / `llm` / `review` are
    /// what the backend log is keyed on. The strings here are the same ones
    /// the three merged phases produced, so backend correlation is unchanged.
    public var stageTag: String {
        processingStage?.stageTag ?? phase.stageTag
    }

    public init(
        phase: SpeechSessionPhase = .idle,
        suspendedPhase: SpeechSessionPhase? = nil,
        isReconnecting: Bool = false,
        failureReason: String? = nil,
        userTurnCount: Int = 0,
        lastTurnOutcome: TurnOutcome? = nil,
        processingStage: ProcessingStage? = nil
    ) {
        self.phase = phase
        self.suspendedPhase = suspendedPhase
        self.isReconnecting = isReconnecting
        self.failureReason = failureReason
        self.userTurnCount = userTurnCount
        self.lastTurnOutcome = lastTurnOutcome
        // Normalised in the safe direction only: a stage that outlives its
        // phase is drift, but a `.processing` phase constructed without a
        // stage is a caller mistake and is left visible rather than papered
        // over with a guess.
        self.processingStage = phase == .processing ? processingStage : nil
    }

    public static let initial = SpeechSessionState()
}
