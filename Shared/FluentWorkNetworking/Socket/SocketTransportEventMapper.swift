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
        case let .control(.aiTurnEnd(turnID, outcome)):
            return .aiTurnEndReceived(turnID: turnID, outcome: outcome)

        case .stateChanged, .control, .audio, .diagnostic:
            return nil
        }
    }
}

/// Stable provider/transport failures must not surface raw socket text (e.g.
/// "write tcp ... broken pipe") to the learner. Known codes get a concise,
/// actionable message; unknown codes keep the raw detail for diagnostics.
private func userFacingErrorText(code: String, rawMessage: String?) -> String {
    switch code {
    case "provider_audio_failed", "provider_control_failed", "provider_open_failed":
        return "语音服务连接中断，请重试"
    case "activate_failed":
        return "会话激活失败，请重试"
    case "client_asr_required":
        return "当前无法识别语音，请重试"
    default:
        return rawMessage?.isEmpty == false ? "[\(code)] \(rawMessage ?? "")" : "[\(code)]"
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
    case aiTurnEndReceived(turnID: String?, outcome: WSControlFrame.TurnOutcome?)
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
