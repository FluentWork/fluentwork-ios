import Testing
@testable import FluentWorkUI

@Test func badgeFeedbackShowsOnlyCurrentBadgeInOverlaySlot() {
    let model = BadgeFeedbackViewModel(
        badges: [
            BadgeFeedbackRow(id: "p-1", badge: "表达自然", tier: .badgeOnly),
            BadgeFeedbackRow(id: "p-2", badge: "Let's ship it.", tier: .badgeOnly),
        ],
        maxVisible: 3
    )

    // Repeated hits rotate in the same slot: the overlay must present only the
    // latest entry instead of stacking (53 §2.4 — 不刷屏).
    #expect(model.currentVisibleBadge?.id == "p-2")
    #expect(model.currentVisibleBadge?.badge == "Let's ship it.")
}

@Test func badgeFeedbackEmptyWhenNoEntries() {
    let model = BadgeFeedbackViewModel()

    #expect(model.isEmpty)
    #expect(model.currentVisibleBadge == nil)
}

@Test func badgeFeedbackCurrentBadgeRespectsMaxVisible() {
    let model = BadgeFeedbackViewModel(
        badges: [
            BadgeFeedbackRow(id: "p-1", badge: "表达自然", tier: .unknown),
            BadgeFeedbackRow(id: "p-2", badge: "节奏稳定", tier: .unknown),
            BadgeFeedbackRow(id: "p-3", badge: "用词地道", tier: .unknown),
            BadgeFeedbackRow(id: "p-4", badge: "太多填充词", tier: .unknown),
        ],
        maxVisible: 2
    )

    #expect(model.visibleBadges.count == 2)
    #expect(model.currentVisibleBadge?.id == "p-2")
}
