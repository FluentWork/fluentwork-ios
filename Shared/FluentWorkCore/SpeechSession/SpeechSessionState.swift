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
    case processingASR
    case processingLLM
    case processingReview
    case degradedText
    case ended
    case failed

    /// Maps the iOS-side phase to the backend's `stage` log tag so the iOS
    /// `timing_phase_transition` log lines up with the backend's
    /// `voice user speech frame`, `voice session ready`, and `session.end
    /// persisted` events when they share the same session id. Mirrors the
    /// voice-gateway handler's `stage` field on
    /// `voiceproto.ProviderOutbound.Control` payloads.
    public var stageTag: String {
        switch self {
        case .idle:             return "idle"
        case .connecting:       return "orchestration"
        case .aiSpeaking:       return "tts"
        case .waitingUser:      return "waiting_user"
        case .recording:        return "vad_capture"
        case .processingASR:    return "asr"
        case .processingLLM:    return "llm"
        case .processingReview: return "review"
        case .degradedText:     return "text_fallback"
        case .ended:            return "ended"
        case .failed:           return "failed"
        }
    }

    /// Live speaking-room phases that still own capture/transport.
    /// Matches `SpeechSessionMachine` — idle / ended / failed are terminal.
    public var isActive: Bool {
        switch self {
        case .idle, .ended, .failed:
            return false
        case .connecting, .aiSpeaking, .waitingUser, .recording,
             .processingASR, .processingLLM, .processingReview, .degradedText:
            return true
        }
    }

    /// True while the machine is in any post-capture processing substage.
    public var isProcessing: Bool {
        processingSubStage != nil
    }

    /// Derived from `phase` so callers do not have to keep a parallel field in sync.
    public var processingSubStage: ProcessingSubStage? {
        switch self {
        case .processingASR: return .asr
        case .processingLLM: return .llm
        case .processingReview: return .review
        default: return nil
        }
    }
}

public enum ProcessingSubStage: String, Equatable, Sendable, Codable {
    case asr
    case llm
    case review
}

public struct SpeechSessionState: Equatable, Sendable {
    public var phase: SpeechSessionPhase
    /// Non-nil while system-interrupted: machine ignores active events until
    /// `systemInterruptEnded` (or end/fail). Captures the phase at suspend time.
    public var suspendedPhase: SpeechSessionPhase?
    public var isReconnecting: Bool
    public var failureReason: String?
    /// Incremented each time the machine enters `.processingASR` from `.recording`,
    /// i.e. once per user speaking turn. Used to populate `user.speech.end`'s
    /// `turn_id` field so the backend can dedupe badge hits per-turn.
    public var userTurnCount: Int
    /// Mirrors `phase.processingSubStage`. Optional stored copy so tests and
    /// telemetry can read the substage without switching on phase; always
    /// kept in lockstep by `SpeechSessionMachine`.
    public var processingSubStage: ProcessingSubStage?

    public init(
        phase: SpeechSessionPhase = .idle,
        suspendedPhase: SpeechSessionPhase? = nil,
        isReconnecting: Bool = false,
        failureReason: String? = nil,
        userTurnCount: Int = 0,
        processingSubStage: ProcessingSubStage? = nil
    ) {
        self.phase = phase
        self.suspendedPhase = suspendedPhase
        self.isReconnecting = isReconnecting
        self.failureReason = failureReason
        self.userTurnCount = userTurnCount
        self.processingSubStage = processingSubStage ?? phase.processingSubStage
    }

    public static let initial = SpeechSessionState()
}
