import Foundation
import TGReduxKit
import TGReduxKitTesting
import Testing

@testable import FluentWorkCore

@Test func badgeFeedbackReducerAcceptsFirstIngest() throws {
    let store = TestStore(initialState: AppState.initial, reducer: appReducer)
    let now = Date(timeIntervalSinceReferenceDate: 1_000)
    let clock = FixedClock(date: now)

    store.send(
        .badgeFeedback(
            .ingest(
                badge: "表达自然",
                turnID: "turn-1",
                tier: .nextTurnConfirm,
                at: clock.now()
            )
        )
    )

    // Two `BadgeFeedEntry`s with equal payloads but auto-generated UUIDs
    // don't compare equal — verify by field instead of full struct.
    let entries = store.state.badgeFeedback.entries
    #expect(entries.count == 1)
    #expect(entries.first?.badge == "表达自然")
    #expect(entries.first?.turnID == "turn-1")
    #expect(entries.first?.tier == .nextTurnConfirm)
    #expect(entries.first?.receivedAt == clock.now())
    #expect(store.state.badgeFeedback.lastTickAt == clock.now())
}

@Test func badgeFeedbackReducerDeduplicatesSameBadgeAndTurn() throws {
    let store = TestStore(initialState: AppState.initial, reducer: appReducer)
    let initial = Date(timeIntervalSinceReferenceDate: 1_000)
    let clock = FixedClock(date: initial)

    store.send(
        .badgeFeedback(
            .ingest(
                badge: "节奏稳定",
                turnID: "turn-A",
                tier: .badgeOnly,
                at: clock.now()
            )
        )
    )
    #expect(store.state.badgeFeedback.entries.count == 1)

    // Same badge + same turnID within dedupe window → suppressed.
    store.send(
        .badgeFeedback(
            .ingest(
                badge: "节奏稳定",
                turnID: "turn-A",
                tier: .badgeOnly,
                at: clock.now()
            )
        )
    )
    #expect(store.state.badgeFeedback.entries.count == 1)

    // Different turnID → not duplicate.
    store.send(
        .badgeFeedback(
            .ingest(
                badge: "节奏稳定",
                turnID: "turn-B",
                tier: .badgeOnly,
                at: clock.now()
            )
        )
    )
    #expect(store.state.badgeFeedback.entries.count == 2)
    #expect(store.state.badgeFeedback.entries.map(\.turnID) == ["turn-A", "turn-B"])
}

@Test func badgeFeedbackReducerDedupeWindowExpires() {
    var state = AppState.initial.badgeFeedback
    state.dedupeWindowSeconds = 5.0

    let base = Date(timeIntervalSinceReferenceDate: 10_000)

    state.ingest(badge: "X", turnID: "t1", tier: .unknown, at: base)
    #expect(state.entries.count == 1)

    // 4s later — still within window.
    state.ingest(badge: "X", turnID: "t1", tier: .unknown, at: base.addingTimeInterval(4))
    #expect(state.entries.count == 1)

    // 10s later (outside window) — accepted.
    state.ingest(badge: "X", turnID: "t1", tier: .unknown, at: base.addingTimeInterval(10))
    #expect(state.entries.count == 2)
}

@Test func badgeFeedbackReducerCapsEntriesToMaxVisible() {
    var state = AppState.initial.badgeFeedback
    state.maxVisibleEntries = 2

    let clock = Date(timeIntervalSinceReferenceDate: 100)

    for index in 0..<5 {
        state.ingest(
            badge: "badge-\(index)",
            turnID: "turn-\(index)",
            tier: .unknown,
            at: clock.addingTimeInterval(Double(index))
        )
    }

    #expect(state.entries.count == 2)
    #expect(state.entries.first?.badge == "badge-3")
    #expect(state.entries.last?.badge == "badge-4")
}

@Test func badgeFeedbackReducerTickDropsExpiredEntries() {
    var state = AppState.initial.badgeFeedback
    state.visibleWindowSeconds = 2.0

    let clock = Date(timeIntervalSinceReferenceDate: 0)

    state.ingest(badge: "old", turnID: "old", tier: .unknown, at: clock)
    state.ingest(badge: "mid", turnID: "mid", tier: .unknown, at: clock.addingTimeInterval(1))

    // Tick 10s later — both should drop (visibleWindowSeconds = 2).
    let cutoff = clock.addingTimeInterval(10).addingTimeInterval(-state.visibleWindowSeconds)
    state.entries.removeAll { $0.receivedAt < cutoff }
    state.lastTickAt = clock.addingTimeInterval(10)

    #expect(state.entries.isEmpty)
}

@Test func badgeFeedbackReducerClearWipesEverything() {
    var state = AppState.initial.badgeFeedback
    state.entries.append(
        BadgeFeedEntry(
            badge: "待清",
            turnID: nil,
            tier: .unknown,
            receivedAt: Date()
        )
    )

    state.entries = []
    state.lastTickAt = nil

    #expect(state.entries.isEmpty)
    #expect(state.lastTickAt == nil)
}

@Test func badgeFeedbackReducerRejectsEmptyBadge() throws {
    let store = TestStore(initialState: AppState.initial, reducer: appReducer)
    store.send(
        .badgeFeedback(
            .ingest(badge: "", turnID: nil, tier: .unknown, at: Date())
        )
    )
    #expect(store.state.badgeFeedback.entries.isEmpty)
}

@Test func badgeFeedbackStateReportsVisibleEntriesByNow() {
    let base = Date(timeIntervalSinceReferenceDate: 5_000)

    var withEntries = AppState.initial.badgeFeedback
    withEntries.entries = [
        BadgeFeedEntry(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            badge: "fresh",
            turnID: nil,
            tier: .unknown,
            receivedAt: base
        ),
        BadgeFeedEntry(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            badge: "stale",
            turnID: nil,
            tier: .unknown,
            receivedAt: base.addingTimeInterval(-10)
        ),
    ]

    let visible = withEntries.visibleEntries(at: base.addingTimeInterval(2))
    #expect(visible.count == 1)
    #expect(visible.first?.badge == "fresh")
}

@Test func speakingRoomBadgeHitTriggersBadgeFeedbackIngest() throws {
    let store = TestStore(initialState: AppState.initial, reducer: appReducer)

    store.send(.speakingRoom(.badgeHit("表达自然")))

    // Equality on `Date` would force us to mirror the unknown wall-clock;
    // instead compare by field.
    #expect(store.state.speakingRoom.lastBadge == "表达自然")
    #expect(store.state.speakingRoom.badgeHits == 1)
    #expect(store.state.workspace.highlightedBadge == "表达自然")
    #expect(store.state.workspace.badgeFeedCount == 1)
    #expect(store.state.badgeFeedback.entries.count == 1)
    #expect(store.state.badgeFeedback.entries.first?.badge == "表达自然")
    #expect(store.state.badgeFeedback.entries.first?.tier == .unknown)
    #expect(store.state.badgeFeedback.entries.first?.turnID == nil)
}
