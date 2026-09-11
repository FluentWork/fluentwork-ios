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
    case degradedText
    case ended
    case failed

    /// A label for this phase. **Mostly iOS-local — not a backend vocabulary.**
    ///
    /// This used to be documented as mirroring the gateway's `stage` field, so
    /// that the iOS `timing_phase_transition` log would "line up with" the
    /// backend's events on the same session id. **That was true for three
    /// values and false for the rest.** The gateway's whole `stage` vocabulary
    /// is `orchestration` / `asr` / `tts` / `scheduler` / `transport`; the iOS
    /// list is longer and mostly names phases the server never logs. (`77_`
    /// P1-20.)
    ///
    /// A correlation field that claims a shared vocabulary has to earn it —
    /// otherwise a reader searches the server log for a label that was never
    /// there and concludes the event was lost. The joined values are pinned by
    /// `StageTagVocabularyTests`, so the claim and the overlap move together.
    ///
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
             .processing, .degradedText:
            return true
        }
    }

    /// Whether the 结束练习 confirmation should still be on screen.
    ///
    /// Live chrome (the red button) is destroyed when the phase leaves
    /// `isActive`. A leftover `true` re-presents the dialog the next time
    /// that chrome appears. Host must **write the flag back** through this
    /// function on every phase change — a computed `get` that still leaves
    /// `@State == true` will pop the dialog again on `.connecting`.
    public func presentingEndSessionConfirmation(_ isPresented: Bool) -> Bool {
        isPresented && isActive
    }

    /// True while the machine is processing the user's last turn.
    public var isProcessing: Bool { self == .processing }
}

/// Where the host may attach the 结束练习 alert.
///
/// The speaking room is a workbench `fullScreenCover`. SwiftUI presents one
/// thing at a time from a given presenter:
///
/// - `liveSessionButton` is destroyed on `.ended` → flag leaks, dialog twice
/// - `fullScreenCoverPresenter` is the view that *presents* the cover
///   (HostRootView). A second presentation from there **dismisses the room**
/// - `speakingRoomDestination` sits inside the cover. The alert must wrap the
///   room ZStack *before* the phase-dependent bottom bar, or `.ended` rebuilds
///   the presenter and a second dialog flashes and auto-dismisses.
public enum EndSessionConfirmationDialogSite: Equatable, Sendable {
    case liveSessionButton
    case fullScreenCoverPresenter
    case speakingRoomDestination

    public var isValid: Bool { self == .speakingRoomDestination }
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
    ///
    /// **No producer today, and the producer cannot be this side of the wire.**
    ///
    /// Who dispatches the event that enters this stage? Only
    /// `.processingStageReached(.review)`, which production never dispatches —
    /// the sole call sites are tests. The signal would have to come from the
    /// gateway, and the gateway emits no `review` stage: its whole vocabulary is
    /// `orchestration` / `asr` / `tts` / `scheduler` / `transport` (`77_` P1-20
    /// counts the same gap as "3/13").
    ///
    /// So this is not a step that runs and is unobserved; it is a step that does
    /// not run. `88_` §⑧ names it as one of the two instances of "定义在、消费分支
    /// 在、测试在，唯独触发者不在" — the shape that costs a reader *knowing one
    /// more thing that is not true*: "AI 的处理会经过三个阶段".
    ///
    /// Kept rather than deleted because the stage is the right shape for the
    /// day the gateway starts emitting the signal, and `P1-15` chose to make the
    /// state readable over removing the seam. Unreachable in production until
    /// then.
    case review
    /// The turn is finished; the backend's scorer has not answered yet.
    ///
    /// Its own stage rather than its own phase because **it is a backend timer,
    /// not a product state.** Giving it a phase is what let F19 hang a
    /// `.stopPlayback` on the 20s budget and cut the tail off every reply
    /// longer than that: the room looked like it had a state for "waiting for
    /// the score", so the timer acquired user-visible behaviour.
    case evaluation
    /// I21: the recording was aborted, and its answer is still on the way.
    ///
    /// Same wait as every other entry into this phase — only the entrance
    /// differs (`docs/29`).
    case aiAnswer

    /// A label for this stage. **Only `asr` is a gateway stage** — the other
    /// four name positions the client tracks and the server never logs.
    ///
    /// The strings are preserved exactly as the merged phases emitted them, so
    /// nothing that already read them changes; what changes is the claim. Only
    /// `asr` appears in the gateway's `stage` vocabulary
    /// (`orchestration` / `asr` / `tts` / `scheduler` / `transport`), so a
    /// cross-log search is worth trying for that one and not for the rest —
    /// see `StageTagVocabularyTests` and `77_` P1-20.
    public var stageTag: String {
        switch self {
        case .asr: return "asr"
        case .llm: return "llm"
        case .review: return "review"
        case .evaluation: return "waiting_for_evaluation"
        case .aiAnswer: return "waiting_for_ai_answer"
        }
    }
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

    /// In-flight AI turn cannot be recovered after the socket comes back.
    /// PCM is not replayed; land in `.waitingUser`.
    ///
    /// **Stage-aware, and that is the point.** This used to be a property of
    /// the phase, which worked only while the two things it separates had
    /// phases of their own: an evaluation wait discards the turn, an abort
    /// landing pad (`aiAnswer`) does not — the user already abandoned that
    /// turn, so there is nothing left to discard and dropping playback would
    /// cut off an answer they are still owed. Merged into one phase, the
    /// distinction has nowhere else to live.
    public var discardsTurnOnReconnect: Bool {
        switch phase {
        case .aiSpeaking:
            return true
        case .processing:
            // The pipeline stages and the evaluation wait belong to a turn
            // that will not be replayed; `aiAnswer` is the abort landing pad.
            return processingStage != .aiAnswer
        case .idle, .connecting, .waitingUser, .recording, .degradedText, .ended, .failed:
            return false
        }
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
