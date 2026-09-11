import Foundation

/// Maps transport-level events into speaking-room actions so failures can reach the Store.
///
/// Badge hits intentionally stay out of the SpeechSession state machine; callers may
/// also dispatch workspace badge feed actions separately (see architecture docs).
public enum SocketTransportEventMapper {
    public static func speakingRoomAction(
        for event: SocketTransportEvent
    ) -> SpeakingRoomTransportAction? {
        switch event {
        case .stateChanged(.connected):
            return .socketReady

        case let .control(.feedbackBadge(badge, phraseBlockID, tier, turnID)):
            // The mapper sits in FluentWorkNetworking, so it hands the raw
            // `FeedbackBadgeTier` (transport enum) to FluentWorkCore, which
            // owns `BadgeFeedEntry.Tier`. The display reducer maps the two
            // value sets together — see `BadgeFeedEntry.Tier.from(transport:)`.
            // `turn_id` is echoed back by the backend on the same user turn
            // the client opened, so the cross-cutting reducer can mirror the
            // backend's dedupe scope.
            return .badgeHit(
                badge: badge,
                phraseBlockID: phraseBlockID,
                tier: tier,
                turnID: turnID
            )

        /// B14: Volcengine Duplex ASR transcript relayed from the backend.
        /// Consumed by SpeechSessionMiddleware to populate the server-side
        /// transcription for this turn, bypassing the local Apple Speech path.
        case let .control(.clientASRTranscription(text, turnID)):
            return .serverASRReceived(text: text, turnID: turnID)

        /// Backend error frame. Surfaces provider failures, ASR gate rejections,
        /// and other transient transport-level conditions that should drop the
        /// session into `.failed` with a stable code for downstream branching.
        case let .control(.error(code, message)):
            return .failed(userFacingErrorText(code: code, rawMessage: message))

        case .failure(.pingTimedOut), .stateChanged(.disconnected):
            return .networkLost

        case let .failure(error):
            return .failed(error.userFacingMessage)

        /// B15: ai.turn.end with explicit outcome. Maps to aiTurnEndReceived so
        /// the middleware can branch on the outcome value (e.g., outcome=timeout
        /// dispatches .failed("turn_timeout")).
        /// B15-I3: log_id is also extracted here and forwarded so the middleware
        /// can store it in the timings recorder for cross-layer trace correlation.
        case let .control(.aiTurnEnd(turnID, outcome, logID)):
            return .aiTurnEndReceived(turnID: turnID, outcome: outcome, logID: logID)

        case .stateChanged, .control, .audio, .diagnostic:
            return nil
        }
    }
}

/// Maps a backend error `code` to text a learner can act on.
///
/// **Every code gets a human sentence.** The previous table covered five of the
/// twelve codes the gateway can send; the rest fell through to the raw machine
/// code, and the split had no rationale — `provider_audio_failed` got a careful
/// line while `provider_start_failed`, its sibling from the same subsystem,
/// rendered as `[provider_start_failed] ...`.
///
/// An unrecognised code still carries its identifier, but as an **appendix to a
/// human sentence** rather than instead of one. A code we have never seen is
/// precisely the case where support needs the identifier and the learner must
/// not be shown it alone.
///
/// Coverage is pinned by `SocketTransportEventMapperErrorCopyTests`, so a new
/// code cannot quietly start rendering as machine text.
///
/// `internal` rather than `private` so that test can reach it.
func userFacingErrorText(code: String, rawMessage: String?) -> String {
    switch code {
    // Upstream provider failures — the whole family, not three of the five.
    case "provider_audio_failed", "provider_control_failed", "provider_open_failed",
         "provider_start_failed":
        return "语音服务连接中断，请重试"
    case "provider_interrupt_failed":
        return "这次打断没有送达，请重试"
    case "activate_failed":
        return "会话激活失败，请重试"
    case "client_asr_required":
        return "当前无法识别语音，请重试"
    case "end_failed":
        return "结束练习时出了点问题，请返回工作台重试"
    // Client-side protocol violations: a bug on our side, not something the
    // learner did — so the copy asks them to retry rather than blaming input.
    case "invalid_frame", "session_not_started", "already_authenticated":
        return "客户端状态异常，请重试"

    default:
        let detail = rawMessage.flatMap { $0.isEmpty ? nil : $0 }
        return detail.map { "语音服务出了点问题，请重试（\(code): \($0)）" }
            ?? "语音服务出了点问题，请重试（\(code)）"
    }
}

/// Transport → feature action surface without forcing FluentWorkNetworking to depend on Core.
public enum SpeakingRoomTransportAction: Equatable, Sendable {
    case socketReady
    case badgeHit(
        badge: String,
        phraseBlockID: String?,
        tier: FeedbackBadgeTier?,
        turnID: String?
    )
    /// B14: Server-side ASR transcription received via WSS relay from Volcengine Duplex.
    case serverASRReceived(text: String, turnID: String?)
    /// B15: ai.turn.end received. `outcome` carries the explicit backend status
    /// (ok / partial / timeout / error); nil outcome means the old pre-B15 protocol.
    /// B15-I3: `logID` carries the vendor trace log_id for cross-layer correlation.
    case aiTurnEndReceived(turnID: String?, outcome: WSControlFrame.TurnOutcome?, logID: String?)
    case failed(String)
    case networkLost
}

extension SocketTransportError {
    public var userFacingMessage: String {
        switch self {
        case .invalidURL:
            return "Invalid speaking-room URL."
        case .notConnected:
            return "Speaking room is not connected."
        case let .handshakeFailed(detail):
            return "Handshake failed: \(detail)"
        case let .encodingFailed(detail):
            return "Failed to encode frame: \(detail)"
        case let .decodingFailed(detail):
            return "Failed to decode frame: \(detail)"
        case let .network(detail):
            return detail
        case .pingTimedOut:
            return "Network connection lost."
        case .cancelled:
            return "Connection cancelled."
        }
    }
}
