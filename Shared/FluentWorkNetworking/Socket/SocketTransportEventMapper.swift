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

        case let .control(.feedbackBadge(badge, phraseBlockID, tier)):
            // The mapper sits in FluentWorkNetworking, so it hands the raw
            // `FeedbackBadgeTier` (transport enum) to FluentWorkCore, which
            // owns `BadgeFeedEntry.Tier`. The display reducer maps the two
            // value sets together — see `BadgeFeedEntry.Tier.from(transport:)`.
            return .badgeHit(
                badge: badge,
                phraseBlockID: phraseBlockID,
                tier: tier,
                turnID: nil
            )

        case .failure(.pingTimedOut), .stateChanged(.disconnected):
            return .networkLost

        case let .failure(error):
            return .failed(error.userFacingMessage)

        case .stateChanged, .control, .audio:
            return nil
        }
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
