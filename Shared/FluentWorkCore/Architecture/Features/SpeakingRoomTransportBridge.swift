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
        // B15: ai.turn.end with explicit outcome. **这里没有可映射的 action，是刻意的**：
        // 真正处理它的是 `SpeechSessionMiddleware`（它会看 outcome 并驱动
        // `.failed("turn_timeout")` 那条路），而 `SocketTransportEventMapper` 永远不产出
        // 这个传输动作 —— 所以从前那个 `SpeakingRoomAction.aiTurnEndReceived` 是一条
        // 到不了 reducer 的 no-op，已删。这一支留着是为了 `switch` 穷举，并写下「为什么不映射」。
        case .aiTurnEndReceived:
            return nil
        }
    }
}
