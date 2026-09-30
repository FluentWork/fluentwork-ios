import FluentWorkCore
import Foundation

extension BadgeFeedbackViewModel {
    /// State → the overlay's plain model.
    ///
    /// `now` is a parameter for the same reason it is on the session list: the window
    /// (`visibleWindowSeconds`) decides which hits are still on screen, so a projection that read the
    /// clock itself could only be checked on the day it was written.
    ///
    /// Entries arrive already sorted by `receivedAt` ascending, and the cap is applied **here** rather
    /// than in the state: `maxVisible` is a display property (`visibleBadges` / `currentVisibleBadge`
    /// live on the model), while the state keeps every entry inside the window so a re-render with a
    /// different cap does not need the events again.
    public static func make(
        from state: BadgeFeedbackState,
        now: Date
    ) -> BadgeFeedbackViewModel {
        let rows = state.visibleEntries(at: now).map { entry in
            BadgeFeedbackRow(
                id: entry.id.uuidString,
                badge: entry.badge,
                tier: tier(from: entry.tier)
            )
        }
        return BadgeFeedbackViewModel(badges: rows, maxVisible: state.maxVisibleEntries)
    }

    /// `BadgeFeedEntry.Tier` → `BadgeFeedbackRow.BadgeTier`.
    ///
    /// Two enums with the same four names, and a switch rather than a `rawValue` bridge: they are
    /// allowed to grow apart (the transport-side one already carries a `FeedbackBadgeTier` mapping of
    /// its own), and a missing case here should be a compile error rather than a silent `nil`.
    private static func tier(from tier: BadgeFeedEntry.Tier) -> BadgeFeedbackRow.BadgeTier {
        switch tier {
        case .sameTurnConfirm: return .sameTurnConfirm
        case .nextTurnConfirm: return .nextTurnConfirm
        case .badgeOnly: return .badgeOnly
        case .unknown: return .unknown
        }
    }
}
