import FluentWorkCore
import FluentWorkNetworking
import Testing

@testable import FluentWorkUI

/// `CorpusViewModel.make(from:)` —— 语料库列表的投影。
///
/// 这一份此前是 `HostRootView` 的 `private func`，住在 **app target**（没有测试 target），
/// 门禁对它的验证到「能编译」为止。
@Suite("语料库的投影")
struct CorpusProjectionTests {

    private func block(
        id: String,
        intentZH: String = "同步进度",
        expressionEN: String = "I'll touch base tomorrow.",
        anchorUserSaid: String = "sync up",
        sceneTag: String = "standup",
        functionTag: String = "report",
        isFavorite: Bool = false,
        updatedAt: String = "2026-09-30T12:00:00Z"
    ) -> PhraseBlock {
        PhraseBlock(
            id: id,
            intentZH: intentZH,
            expressionEN: expressionEN,
            anchorUserSaid: anchorUserSaid,
            sceneTag: sceneTag,
            functionTag: functionTag,
            state: "new",
            successStreak: 0,
            nextDueAt: "2026-10-01T00:00:00Z",
            easeFactor: 2.5,
            realUseCount: 0,
            isFavorite: isFavorite,
            pinnedAt: nil,
            sourceSessionID: nil,
            createdAt: "2026-09-30T12:00:00Z",
            updatedAt: updatedAt
        )
    }

    /// 五个屏幕相位一一对应（含 `migrating` —— 它是最容易被漏掉的那个）。
    @Test func 五个相位一一对应() {
        let expected: [(CorpusScreenPhase, CorpusViewPhase)] = [
            (.idle, .idle),
            (.loading, .loading),
            (.ready, .ready),
            (.failed, .failed),
            (.migrating, .migrating),
        ]

        for (state, view) in expected {
            var s = CorpusState()
            s.phase = state
            #expect(CorpusViewModel.make(from: s).phase == view, "\(state) 没有映成 \(view)")
        }
    }

    /// **行来自 `visibleItems`，不是 `items`。**
    ///
    /// 搜索与「只看收藏」这两条筛选规则住在 state 的 `visibleItems` 里。投影若读原始
    /// `items`，筛选规则就会有第二处实现 —— 一处负责筛、一处负责画，而两处迟早不一致。
    @Test func 行来自筛选之后的那一份() {
        var state = CorpusState()
        state.phase = .ready
        state.items = [
            block(id: "b1", expressionEN: "I'll touch base tomorrow."),
            block(id: "b2", expressionEN: "Let's wrap up the review."),
        ]

        // 没有筛选时两行都在。
        #expect(CorpusViewModel.make(from: state).rows.count == 2)

        // 搜索命中一行。
        state.searchQuery = "wrap up"
        let searched = CorpusViewModel.make(from: state)
        #expect(searched.rows.map(\.id) == ["b2"], "搜索没有作用在投影的行上")
        #expect(searched.searchQuery == "wrap up", "搜索词本身也要到屏幕上（输入框要显示它）")
        // 原始列表**不动** —— 它仍然装着两行，是筛选把它挡住了。
        #expect(state.items.count == 2)

        // 只看收藏：一条都不收藏 → 空。
        state.searchQuery = ""
        state.favoriteOnly = true
        #expect(CorpusViewModel.make(from: state).rows.isEmpty)

        state.items[1].isFavorite = true
        #expect(CorpusViewModel.make(from: state).rows.map(\.id) == ["b2"])
        #expect(CorpusViewModel.make(from: state).favoriteOnly)
    }

    /// 行的十个字段逐个转发，两个「待同步」标记来自**待办表**而不是块本身。
    @Test func 每一行转发十个字段() {
        var state = CorpusState()
        state.phase = .ready
        state.items = [
            block(
                id: "b1",
                intentZH: "报告阻塞",
                expressionEN: "I'm blocked on the API review.",
                anchorUserSaid: "blocked",
                sceneTag: "standup",
                functionTag: "report",
                isFavorite: true,
                updatedAt: "2026-09-29T08:30:00Z"
            )
        ]
        state.pendingIndicators = [
            CorpusPendingIndicator(blockID: "b1", operation: .favorite),
            CorpusPendingIndicator(blockID: "b1", operation: .delete),
        ]

        let row = CorpusViewModel.make(from: state).rows[0]

        #expect(row.id == "b1")
        #expect(row.intentZH == "报告阻塞")
        #expect(row.expressionEN == "I'm blocked on the API review.")
        #expect(row.anchorUserSaid == "blocked")
        #expect(row.sceneTag == "standup")
        #expect(row.functionTag == "report")
        #expect(row.isFavorite)
        #expect(row.updatedAt == "2026-09-29T08:30:00Z")
        #expect(row.hasPendingFavorite)
        #expect(row.hasPendingDelete)
    }

    /// 两个待同步标记**各自独立** —— 只待同步删除时不许把收藏也标上。
    @Test func 两个待同步标记各自独立() {
        var state = CorpusState()
        state.phase = .ready
        state.items = [block(id: "b1"), block(id: "b2")]
        state.pendingIndicators = [CorpusPendingIndicator(blockID: "b1", operation: .delete)]

        let rows = CorpusViewModel.make(from: state).rows

        #expect(rows[0].hasPendingDelete)
        #expect(rows[0].hasPendingFavorite == false)
        #expect(rows[1].hasPendingDelete == false, "别的行的标记串到它身上了")
        #expect(rows[1].hasPendingFavorite == false)
    }

    /// 分页、刷新、重放、错误：四个独立维度。
    @Test func 刷新分页与错误各自独立() {
        var state = CorpusState()
        state.phase = .ready
        state.nextCursor = "cursor-2"
        state.isRefreshing = true
        state.isReplayingOutbox = true
        state.lastErrorMessage = "刷新失败"

        let model = CorpusViewModel.make(from: state)

        #expect(model.canLoadMore)
        #expect(model.isRefreshing)
        #expect(model.isReplayingOutbox)
        #expect(model.errorMessage == "刷新失败")

        state.nextCursor = nil
        state.isRefreshing = false
        #expect(CorpusViewModel.make(from: state).canLoadMore == false)
        // 重放与错误与游标无关，不该被顺手清掉。
        #expect(CorpusViewModel.make(from: state).isReplayingOutbox)
        #expect(CorpusViewModel.make(from: state).errorMessage == "刷新失败")
    }

    /// 空语料库：相位仍是 `.ready`（服务端说「你没有块」不是失败），行是空的。
    @Test func 空语料库是就绪不是失败() {
        var state = CorpusState()
        state.phase = .ready

        let model = CorpusViewModel.make(from: state)

        #expect(model.phase == .ready)
        #expect(model.rows.isEmpty)
        #expect(model.canLoadMore == false)
    }
}
