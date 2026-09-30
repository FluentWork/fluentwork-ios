import FluentWorkCore
import Foundation
import Testing

@testable import FluentWorkUI

/// `BadgeFeedbackViewModel.make(from:now:)` —— 徽标浮层的投影。
///
/// 这一份此前是 `HostRootView` 的 `private func`（连 `mapTier` 一起），住在 **app target**
/// （没有测试 target）。
@Suite("徽标浮层的投影")
struct BadgeFeedbackProjectionTests {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func entry(
        badge: String,
        secondsAgo: Double,
        tier: BadgeFeedEntry.Tier = .badgeOnly,
        id: UUID = UUID()
    ) -> BadgeFeedEntry {
        BadgeFeedEntry(
            id: id,
            badge: badge,
            phraseBlockID: nil,
            turnID: nil,
            tier: tier,
            receivedAt: now.addingTimeInterval(-secondsAgo)
        )
    }

    /// **窗口内的留下、窗口外的走掉，而「现在」是传进来的。**
    ///
    /// 这条判据是这次搬迁的重点：投影以前在内部读 `Date()`，于是「哪些命中还在屏幕上」在任何
    /// 测试里都不可控。把 `now` 收成参数之后，同一个状态在两个「现在」下必须给出不同的浮层 ——
    /// 实现里若还偷偷留着 `Date()`，两次结果就会一样。
    @Test func 窗口决定谁还在屏幕上() {
        var state = BadgeFeedbackState()
        state.visibleWindowSeconds = 4
        state.entries = [
            entry(badge: "刚命中", secondsAgo: 1),
            entry(badge: "早该走了", secondsAgo: 10),
        ]

        let fresh = BadgeFeedbackViewModel.make(from: state, now: now)
        #expect(fresh.badges.map(\.badge) == ["刚命中"])

        // 把「现在」推后 5 秒：连那一条也过期了。
        let later = BadgeFeedbackViewModel.make(
            from: state,
            now: now.addingTimeInterval(5)
        )
        #expect(
            later.badges.isEmpty,
            "换了一个「现在」结果却没变 —— `now` 参数没被真正使用"
        )
    }

    /// 窗口内按**到达顺序**（旧的在前），因为浮层是在同一个位置轮换、显示最新那一条。
    @Test func 窗口内按到达顺序排列() {
        var state = BadgeFeedbackState()
        state.visibleWindowSeconds = 10
        state.entries = [
            entry(badge: "第二", secondsAgo: 2),
            entry(badge: "第一", secondsAgo: 5),
            entry(badge: "第三", secondsAgo: 1),
        ]

        let model = BadgeFeedbackViewModel.make(from: state, now: now)

        #expect(model.badges.map(\.badge) == ["第一", "第二", "第三"])
        #expect(model.currentVisibleBadge?.badge == "第三", "轮换位置上应该是最新那一条")
    }

    /// 四个档位**逐个**对应 —— 不能只测其中一个。
    ///
    /// 两个 enum 名字一样（`BadgeFeedEntry.Tier` 与 `BadgeFeedbackRow.BadgeTier`），映射是手写的
    /// switch；只测一档的话，其余三档映对没映对都看不出来。
    @Test func 四个档位逐个对应() {
        let expected: [(BadgeFeedEntry.Tier, BadgeFeedbackRow.BadgeTier)] = [
            (.sameTurnConfirm, .sameTurnConfirm),
            (.nextTurnConfirm, .nextTurnConfirm),
            (.badgeOnly, .badgeOnly),
            (.unknown, .unknown),
        ]

        for (entryTier, rowTier) in expected {
            var state = BadgeFeedbackState()
            state.entries = [entry(badge: "x", secondsAgo: 0, tier: entryTier)]
            let model = BadgeFeedbackViewModel.make(from: state, now: now)
            #expect(model.badges.first?.tier == rowTier, "\(entryTier) 没有映成 \(rowTier)")
        }
    }

    /// 每一条的身份来自它自己的 id —— 同一句话命中两次是两个不同的 id，不许撞。
    @Test func 两条命中各有各的身份() {
        let first = UUID()
        let second = UUID()
        var state = BadgeFeedbackState()
        state.entries = [
            entry(badge: "同一句话", secondsAgo: 2, id: first),
            entry(badge: "同一句话", secondsAgo: 1, id: second),
        ]

        let model = BadgeFeedbackViewModel.make(from: state, now: now)

        #expect(model.badges.map(\.id) == [first.uuidString, second.uuidString])
        #expect(Set(model.badges.map(\.id)).count == 2, "两条命中撞了身份")
    }

    /// 上限是**显示**属性：状态留着窗口内的全部，模型只画前几条。
    @Test func 上限决定画几条但状态不被截断() {
        var state = BadgeFeedbackState()
        state.visibleWindowSeconds = 30
        state.maxVisibleEntries = 2
        state.entries = [
            entry(badge: "一", secondsAgo: 3),
            entry(badge: "二", secondsAgo: 2),
            entry(badge: "三", secondsAgo: 1),
        ]

        let model = BadgeFeedbackViewModel.make(from: state, now: now)

        #expect(model.maxVisible == 2)
        #expect(model.badges.count == 3, "状态里窗口内的三条都要在模型里 —— 截断是 `visibleBadges` 的事")
        #expect(model.visibleBadges.map(\.badge) == ["一", "二"])
        #expect(model.currentVisibleBadge?.badge == "二")
        #expect(state.entries.count == 3, "投影改动了状态")
    }

    /// 一条都没有 → 空模型而不是崩掉。
    @Test func 没有命中就是空的() {
        let model = BadgeFeedbackViewModel.make(from: BadgeFeedbackState(), now: now)

        #expect(model.badges.isEmpty)
        #expect(model.visibleBadges.isEmpty)
        #expect(model.currentVisibleBadge == nil)
        #expect(model.isEmpty)
    }
}
