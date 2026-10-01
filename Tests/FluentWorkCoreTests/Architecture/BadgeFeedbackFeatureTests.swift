import Foundation
import FluentWorkNetworking
import TGReduxKit
import TGReduxKitTesting
import Testing

@testable import FluentWorkCore

// 这一个文件里五条判据从前派 `.badgeFeedback(...)`（那一族 action 已删，没有任何派发者）。
// 它们测的 ingest / 去重语义一条没少，改成直接调**真正生效的那个入口**
// （`BadgeFeedbackState.ingest`，也就是 `appCrossCuttingReducer` 调的那个方法）。
@Test func badgeFeedbackIngestAcceptsFirstHit() throws {
    var state = AppState.initial.badgeFeedback
    let now = Date(timeIntervalSinceReferenceDate: 1_000)
    let clock = FixedClock(date: now)

    state.ingest(badge: "表达自然", turnID: "turn-1", tier: .nextTurnConfirm, at: clock.now())

    // Two `BadgeFeedEntry`s with equal payloads but auto-generated UUIDs
    // don't compare equal — verify by field instead of full struct.
    let entries = state.entries
    #expect(entries.count == 1)
    #expect(entries.first?.badge == "表达自然")
    #expect(entries.first?.turnID == "turn-1")
    #expect(entries.first?.tier == .nextTurnConfirm)
    #expect(entries.first?.receivedAt == clock.now())
}

@Test func badgeFeedbackIngestDeduplicatesSameBadgeAndTurn() throws {
    var state = AppState.initial.badgeFeedback
    let initial = Date(timeIntervalSinceReferenceDate: 1_000)
    let clock = FixedClock(date: initial)

    state.ingest(badge: "节奏稳定", turnID: "turn-A", tier: .badgeOnly, at: clock.now())
    #expect(state.entries.count == 1)

    // Same badge + same turnID within dedupe window → suppressed.
    state.ingest(badge: "节奏稳定", turnID: "turn-A", tier: .badgeOnly, at: clock.now())
    #expect(state.entries.count == 1)

    // Different turnID → not duplicate.
    state.ingest(badge: "节奏稳定", turnID: "turn-B", tier: .badgeOnly, at: clock.now())
    #expect(state.entries.count == 2)
    #expect(state.entries.map(\.turnID) == ["turn-A", "turn-B"])
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

/// **「没有定时清扫」是设计，不是遗漏。**
///
/// 过期只体现在**读**上：`visibleEntries(at:)` 按窗口算，`entries` 不会自己变短。
/// 从前有一条 `tick` action 专门做清扫（没人派发），而它为它写的那条判据也没在测生产代码 ——
/// 它在测试里把 cutoff 公式抄了一遍再断言自己抄对了。这条改成测真的那条路。
@Test func expiredEntriesLeaveTheVisibleSetWithoutAnySweep() {
    var state = AppState.initial.badgeFeedback
    state.visibleWindowSeconds = 2.0

    let clock = Date(timeIntervalSinceReferenceDate: 0)
    state.ingest(badge: "old", turnID: "old", tier: .unknown, at: clock)
    state.ingest(badge: "mid", turnID: "mid", tier: .unknown, at: clock.addingTimeInterval(1))

    // 窗口内：两条都在，按时间升序。
    #expect(state.visibleEntries(at: clock.addingTimeInterval(1)).map(\.badge) == ["old", "mid"])

    // 10 秒后：可读集合空了，但 `entries` 一条没少 —— 没有清扫者。
    #expect(state.visibleEntries(at: clock.addingTimeInterval(10)).isEmpty)
    #expect(state.entries.count == 2, "`entries` 被谁悄悄清掉了 —— 不该有定时器")
}

// `badgeFeedbackReducerClearWipesEverything` 已删：它测的是「把数组设成空数组，然后断言它是空的」，
// 而 `clear` 那条 action 没有任何派发者 —— 判据与它一起走了。

@Test func badgeFeedbackIngestRejectsEmptyBadge() throws {
    var state = AppState.initial.badgeFeedback
    state.ingest(badge: "", turnID: nil, tier: .unknown, at: Date())
    #expect(state.entries.isEmpty)
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

    store.send(AppAction.speakingRoom(.badgeHit(badge: "表达自然")))

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
    #expect(store.state.badgeFeedback.entries.first?.phraseBlockID == nil)
}

@Test func speakingRoomBadgeHitWithEnrichmentIsForwardedToBadgeFeedbackIngest() throws {
    let store = TestStore(initialState: AppState.initial, reducer: appReducer)

    store.send(
        AppAction.speakingRoom(.badgeHit(
            badge: "节奏稳定",
            phraseBlockID: "block-42",
            tier: .nextTurnConfirm,
            turnID: "turn-1"
        ))
    )

    // The cross-cutting mirror must keep the structured payload all the way
    // to the display layer so a single source of truth is maintained.
    #expect(store.state.badgeFeedback.entries.count == 1)
    #expect(store.state.badgeFeedback.entries.first?.phraseBlockID == "block-42")
    #expect(store.state.badgeFeedback.entries.first?.turnID == "turn-1")
    #expect(store.state.badgeFeedback.entries.first?.tier == .nextTurnConfirm)
}

@Test func badgeFeedbackDedupeRespectsPhraseBlockID() {
    var state = AppState.initial.badgeFeedback
    state.dedupeWindowSeconds = 5.0

    let base = Date(timeIntervalSinceReferenceDate: 20_000)

    // Same badge + same turnID + same phraseBlock → duplicate.
    state.ingest(
        badge: "X",
        turnID: "turn-1",
        tier: .unknown,
        at: base,
        phraseBlockID: "block-A"
    )
    state.ingest(
        badge: "X",
        turnID: "turn-1",
        tier: .unknown,
        at: base.addingTimeInterval(1),
        phraseBlockID: "block-A"
    )
    #expect(state.entries.count == 1)

    // Different phraseBlockID → not a duplicate, accepted.
    state.ingest(
        badge: "X",
        turnID: "turn-1",
        tier: .unknown,
        at: base.addingTimeInterval(2),
        phraseBlockID: "block-B"
    )
    #expect(state.entries.count == 2)
    #expect(state.entries.map(\.phraseBlockID) == ["block-A", "block-B"])
}

// Mock-mode coverage of runbook §3 Case 2 — backend hit-detection lands
// `feedback.badge` at the iOS boundary more than once for the same
// (turn, phrase_block) pair within the 5s dedupe window. iOS local
// dedupe must collapse those to a single entry; once the window elapses,
// the next ingest becomes a fresh entry. Pin both halves so a future
// change to `dedupeWindowSeconds` semantics surfaces in CI.
@Test func badgeFeedbackDedupeHonorsTimeWindowTTL() {
    var state = AppState.initial.badgeFeedback
    state.dedupeWindowSeconds = 5.0

    let base = Date(timeIntervalSinceReferenceDate: 30_000)

    state.ingest(
        badge: "表达自然",
        turnID: "turn-1",
        tier: .unknown,
        at: base,
        phraseBlockID: "block-X"
    )
    // Same key 2s later — still inside TTL → dropped.
    state.ingest(
        badge: "表达自然",
        turnID: "turn-1",
        tier: .unknown,
        at: base.addingTimeInterval(2),
        phraseBlockID: "block-X"
    )
    #expect(state.entries.count == 1)

    // Same key 6s later — TTL expired → new entry.
    state.ingest(
        badge: "表达自然",
        turnID: "turn-1",
        tier: .unknown,
        at: base.addingTimeInterval(6),
        phraseBlockID: "block-X"
    )
    #expect(state.entries.count == 2)
    #expect(state.entries.map(\.phraseBlockID) == ["block-X", "block-X"])

    // Next turn — turn_id bumps → dedupe key no longer matches.
    state.ingest(
        badge: "表达自然",
        turnID: "turn-2",
        tier: .unknown,
        at: base.addingTimeInterval(6.5),
        phraseBlockID: "block-X"
    )
    #expect(state.entries.count == 3)
    #expect(state.entries.last?.turnID == "turn-2")
}

@Test func badgeFeedEntryTierFromTransportMapping() {
    // The mapping is intentionally lossy and documented in
    // `BadgeFeedEntry.Tier.from(transport:)`. Pin the contract so any
    // accidental change is caught at the reducer / bridge boundary.
    #expect(BadgeFeedEntry.Tier.from(transport: .soft) == .badgeOnly)
    #expect(BadgeFeedEntry.Tier.from(transport: .highlight) == .nextTurnConfirm)
    #expect(BadgeFeedEntry.Tier.from(transport: .celebrate) == .sameTurnConfirm)
}
