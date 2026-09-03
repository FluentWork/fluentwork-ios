import FluentWorkNetworking
import Foundation

extension SpeakingRoomAction {
    /// Bridges transport-level events into speaking-room actions for Store dispatch.
    public init?(_ transportAction: SpeakingRoomTransportAction) {
        switch transportAction {
        case .socketReady:
            self = .session(.socketReady)
        case let .badgeHit(badge, phraseBlockID, tier, turnID):
            // The wire-format tier (`FeedbackBadgeTier`) needs translation into the
            // display `BadgeFeedEntry.Tier` so the cross-cutting reducer can ingest
            // a single canonical value. The mapping is intentionally lossy — see
            // `BadgeFeedEntry.Tier.from(transport:)` for the documented mapping.
            let displayTier = tier.map(BadgeFeedEntry.Tier.from(transport:))
            self = .badgeHit(
                badge: badge,
                phraseBlockID: phraseBlockID,
                tier: displayTier,
                turnID: turnID
            )
        case let .failed(message):
            self = .session(.failed(message))
        case .networkLost:
            self = .session(.networkLost)
        case let .serverASRReceived(text, turnID):
            self = .serverASRReceived(text: text, turnID: turnID)
        // B15: ai.turn.end with explicit outcome. The bridge exists to satisfy the
        // Swift exhaustive switch — the actual handling is done directly in
        // SpeechSessionMiddleware via the SocketTransportEvent.switch so the outcome
        // value can be inspected and drive the .failed("turn_timeout") path.
        case let .aiTurnEndReceived(turnID, outcome):
            self = .aiTurnEndReceived(turnID: turnID, outcome: outcome)
        }
    }
}
