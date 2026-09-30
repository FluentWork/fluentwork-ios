import FluentWorkCore
import FluentWorkNetworking
import Foundation
import Testing

@testable import FluentWorkUI

/// 会话历史（列表 + 详情）的投影。
///
/// 两份此前都是 `HostRootView` 的 `private func`，住在 **app target**（没有测试 target）。
/// 更要紧的是：它们**自己在里面读 `Date()`**，所以「今天 / 昨天 / 9月10日」这三档文案在任何
/// 判据里都是不可重现的 —— 只有恰好在同一天、同一个时区跑的测试才对得上。
/// 搬出来之后 `now` 与 `calendar` 都是参数，文案才第一次可以被钉住。
@Suite("会话历史的投影")
struct SessionHistoryProjectionTests {

    /// 固定日历与时区，让「今天 / 昨天」在任何机器上都是同一个答案。
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        c.locale = Locale(identifier: "zh_Hans_CN")
        return c
    }()

    /// 2026-09-30 14:32（上海的下午）。
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 14, minute: 32))!
    }

    private func item(
        id: String,
        startedAt: Date,
        durationSec: Int = 154,
        status: String = "ended"
    ) -> SessionHistoryItem {
        SessionHistoryItem(
            sessionID: id,
            sceneType: "standup",
            status: status,
            startedAt: startedAt,
            durationSec: durationSec
        )
    }

    // MARK: - 列表

    /// 五个状态相位一一对应。
    @Test func 列表的五个相位一一对应() {
        let expected: [(SessionListPhase, SessionHistoryViewPhase)] = [
            (.idle, .idle),
            (.loading, .loading),
            (.ready, .ready),
            (.empty, .empty),
            (.failed("boom"), .failed),
        ]

        for (state, view) in expected {
            var s = SessionHistoryState()
            s.phase = state
            let model = SessionHistoryViewModel.make(from: s, now: now, calendar: calendar)
            #expect(model.phase == view, "\(state) 没有映成 \(view)")
        }
    }

    /// **`now` 必须真的被用上。**
    ///
    /// 这条判据是这次搬迁的重点：投影以前自己调 `Date()`，于是「今天」这个字样在任何测试里
    /// 都不可控。把 `now` 收成参数之后，同一条记录在两个不同的「现在」下必须给出两句话 ——
    /// 如果实现里还偷偷留着 `Date()`，这两句话就会一模一样，判据立刻红。
    @Test func 同一场练习在不同的一天有两个说法() {
        let started = calendar.date(
            from: DateComponents(year: 2026, month: 9, day: 30, hour: 14, minute: 32)
        )!
        var state = SessionHistoryState()
        state.phase = .ready
        state.items = [item(id: "s-1", startedAt: started)]

        let sameDay = SessionHistoryViewModel.make(from: state, now: now, calendar: calendar)
        #expect(sameDay.rows.first?.startedAtText == "今天 14:32")

        // 把「现在」推到第二天：同一条记录就该变成「昨天」。
        let nextDay = calendar.date(byAdding: .day, value: 1, to: now)!
        let asYesterday = SessionHistoryViewModel.make(from: state, now: nextDay, calendar: calendar)
        #expect(
            asYesterday.rows.first?.startedAtText == "昨天 14:32",
            "换了一天说法没变 —— `now` 参数没有被真正使用：\(asYesterday.rows.first?.startedAtText ?? "nil")"
        )

        // 推到同一年但更远的日子 → 月日；推到下一年 → 带年。
        // （记录本身还是 9月30日 —— 变的是「现在」。）
        let later = calendar.date(byAdding: .day, value: 10, to: now)!
        #expect(
            SessionHistoryViewModel.make(from: state, now: later, calendar: calendar)
                .rows.first?.startedAtText == "9月30日 14:32"
        )
        let nextYear = calendar.date(byAdding: .year, value: 1, to: now)!
        #expect(
            SessionHistoryViewModel.make(from: state, now: nextYear, calendar: calendar)
                .rows.first?.startedAtText == "2026年9月30日 14:32"
        )
    }

    /// 行的三个文案与身份都从记录来（时长尤其：`154` → `2 分 34 秒`）。
    @Test func 列表的每一行都从记录算出来() {
        var state = SessionHistoryState()
        state.phase = .ready
        state.items = [
            item(id: "s-1", startedAt: now, durationSec: 154, status: "ended"),
            item(id: "s-2", startedAt: now, durationSec: 0, status: "abandoned"),
        ]

        let model = SessionHistoryViewModel.make(from: state, now: now, calendar: calendar)

        #expect(model.rows.map(\.id) == ["s-1", "s-2"])
        #expect(model.rows[0].durationText == "2 分 34 秒")
        #expect(model.rows[1].durationText == "不足 1 秒", "零时长被写成了「0 秒」")
        #expect(model.rows[1].statusText != model.rows[0].statusText, "两种状态给出了同一句话")
    }

    /// 分页与错误：`hasMore` 由游标决定，加载中与错误各自独立。
    @Test func 分页与错误各自独立() {
        var state = SessionHistoryState()
        state.phase = .ready
        state.nextCursor = "cursor-2"
        state.isLoadingMore = true
        state.errorMessage = "加载更多失败"

        let model = SessionHistoryViewModel.make(from: state, now: now, calendar: calendar)

        #expect(model.canLoadMore)
        #expect(model.isLoadingMore)
        #expect(model.errorMessage == "加载更多失败")

        state.nextCursor = nil
        #expect(
            SessionHistoryViewModel.make(from: state, now: now, calendar: calendar).canLoadMore
                == false
        )
    }

    /// 空列表：相位是 `.empty`，行也是空的 —— 不是 `.failed`。
    @Test func 没有记录不等于加载失败() {
        var state = SessionHistoryState()
        state.phase = .empty

        let model = SessionHistoryViewModel.make(from: state, now: now, calendar: calendar)

        #expect(model.phase == .empty)
        #expect(model.rows.isEmpty)
        #expect(model.errorMessage == nil)
    }

    // MARK: - 详情

    private func detail(utterances: [SessionUtterance]) -> SessionDetail {
        SessionDetail(
            sessionID: "s-1",
            sceneType: "standup",
            status: "ended",
            startedAt: now,
            durationSec: 154,
            utterances: utterances
        )
    }

    /// 四个状态相位一一对应。
    @Test func 详情的四个相位一一对应() {
        let expected: [(SessionDetailPhase, SessionDetailViewPhase)] = [
            (.idle, .idle),
            (.loading, .loading),
            (.ready, .ready),
            (.failed("boom"), .failed),
        ]

        for (state, view) in expected {
            var s = SessionHistoryDetailState()
            s.phase = state
            let model = SessionDetailViewModel.make(from: s, now: now, calendar: calendar)
            #expect(model.phase == view, "\(state) 没有映成 \(view)")
        }
    }

    /// 还没拿到详情时只给相位，两个文案字段留空而不是给半截内容。
    @Test func 没有详情时只给相位() {
        var state = SessionHistoryDetailState()
        state.phase = .loading

        let model = SessionDetailViewModel.make(from: state, now: now, calendar: calendar)

        #expect(model.phase == .loading)
        #expect(model.subtitleText.isEmpty)
        #expect(model.turns.isEmpty)
    }

    /// 副标题是「时间 · 时长」两段拼起来的。
    @Test func 副标题是时间加时长() {
        var state = SessionHistoryDetailState()
        state.phase = .ready
        state.detail = detail(utterances: [])

        let model = SessionDetailViewModel.make(from: state, now: now, calendar: calendar)

        #expect(model.subtitleText == "今天 14:32 · 2 分 34 秒")
    }

    /// **轮次按 `seq` 排序** —— 服务端的顺序不保证，而错序的对话读起来是乱的。
    @Test func 轮次按序号排序() {
        var state = SessionHistoryDetailState()
        state.phase = .ready
        state.detail = detail(utterances: [
            SessionUtterance(seq: 3, speaker: "user", text: "third"),
            SessionUtterance(seq: 1, speaker: "ai", text: "first"),
            SessionUtterance(seq: 2, speaker: "user", text: "second"),
        ])

        let model = SessionDetailViewModel.make(from: state, now: now, calendar: calendar)

        #expect(model.turns.map(\.id) == [1, 2, 3])
        #expect(model.turns.map(\.text) == ["first", "second", "third"])
    }

    /// 说话人标签：`user` → 我，`ai` → AI，**认不出的保留原名**。
    ///
    /// 认不出的那一种不许被折进「AI」：这一屏是唯一一处「每一轮都必须能归到某个人」的地方，
    /// 标错人比露出一个读者没见过的词更坏。
    @Test func 认不出的说话人保留原名() {
        var state = SessionHistoryDetailState()
        state.phase = .ready
        state.detail = detail(utterances: [
            SessionUtterance(seq: 1, speaker: "user", text: "hi"),
            SessionUtterance(seq: 2, speaker: "ai", text: "hello"),
            SessionUtterance(seq: 3, speaker: "coach", text: "try again"),
        ])

        let model = SessionDetailViewModel.make(from: state, now: now, calendar: calendar)

        #expect(model.turns.map(\.speakerLabel) == ["我", "AI", "coach"])
        #expect(model.turns.map(\.isUser) == [true, false, false])
    }

    /// 失败的那句话要带上 —— **包括还没有 detail 的那条路**。
    ///
    /// 这条判据先红过，红得有内容：投影原来把 `errorMessage` 只放在「有 detail」那条出口上，
    /// 而**拉一个会话失败时根本没有 detail** ⇒ 服务端给的原因被丢掉，屏幕退到那句通用兜底
    /// 「检查网络后重试。」（`SessionDetailView.swift:95` 的 `??`）。
    /// 相邻的列表投影是无条件传递的，两处不一致，而这一层此前在 app target、零判据。
    @Test func 失败原因随相位而来且不依赖有没有详情() {
        // ① 还没有 detail（失败最常见的样子）
        var noDetail = SessionHistoryDetailState()
        noDetail.phase = .failed("这一场读不到")
        #expect(
            SessionDetailViewModel.make(from: noDetail, now: now, calendar: calendar).errorMessage
                == "这一场读不到",
            "没有 detail 时把失败原因丢了 —— 屏幕只会显示通用兜底"
        )
        // 失败态下两个文案字段仍然是空的，不许给半截内容。
        let failedModel = SessionDetailViewModel.make(from: noDetail, now: now, calendar: calendar)
        #expect(failedModel.phase == .failed)
        #expect(failedModel.subtitleText.isEmpty)
        #expect(failedModel.turns.isEmpty)

        // ② 有 detail（上一场还在屏幕上）时同样要带上
        var withDetail = SessionHistoryDetailState()
        withDetail.phase = .failed("刷新失败")
        withDetail.detail = detail(utterances: [])
        #expect(
            SessionDetailViewModel.make(from: withDetail, now: now, calendar: calendar).errorMessage
                == "刷新失败"
        )

        // ③ 不在失败相位时必须是 nil（而不是空串）—— 否则屏幕会画一个空的错误条。
        var ok = SessionHistoryDetailState()
        ok.phase = .ready
        ok.detail = detail(utterances: [])
        #expect(
            SessionDetailViewModel.make(from: ok, now: now, calendar: calendar).errorMessage == nil
        )
    }

    /// 副标题里的时间也要跟着 `now` 走（同一条判据在详情这一侧再钉一次）。
    @Test func 详情的时间也随现在而变() {
        var state = SessionHistoryDetailState()
        state.phase = .ready
        state.detail = detail(utterances: [])

        let nextDay = calendar.date(byAdding: .day, value: 1, to: now)!
        let model = SessionDetailViewModel.make(from: state, now: nextDay, calendar: calendar)

        #expect(model.subtitleText == "昨天 14:32 · 2 分 34 秒")
    }
}
