import FluentWorkCore
import FluentWorkNetworking
import Testing

@testable import FluentWorkUI

/// 屏 08 还原时新增的那几条判据：进步证据、双维度筛选、两种空态、计数。
///
/// 与 `CorpusProjectionTests` 分开：那一份管「列表投影的基本形状」（相位、转发、待同步标记），
/// 这一份管**稿子 屏 08 里那些非它不可的规则**。混在一起的话，改屏 08 的人会在两百行里
/// 找不着哪几条是这次要动的。
@Suite("语料库 · 屏 08 的规则")
struct CorpusCardProjectionTests {

    private func block(
        id: String,
        intentZH: String = "同步进度",
        expressionEN: String = "I'll touch base tomorrow.",
        anchorUserSaid: String = "sync up",
        sceneTag: String = "standup",
        functionTag: String = "report",
        state: String = "new",
        realUseCount: Int = 0,
        isFavorite: Bool = false
    ) -> PhraseBlock {
        PhraseBlock(
            id: id,
            intentZH: intentZH,
            expressionEN: expressionEN,
            anchorUserSaid: anchorUserSaid,
            sceneTag: sceneTag,
            functionTag: functionTag,
            state: state,
            successStreak: 0,
            nextDueAt: "2026-10-01T00:00:00Z",
            easeFactor: 2.5,
            realUseCount: realUseCount,
            isFavorite: isFavorite,
            pinnedAt: nil,
            sourceSessionID: nil,
            createdAt: "2026-09-30T12:00:00Z",
            updatedAt: "2026-09-30T12:00:00Z"
        )
    }

    private func state(
        _ blocks: [PhraseBlock],
        nextCursor: String? = nil,
        sceneFilter: String? = nil,
        functionFilter: String? = nil,
        searchQuery: String = "",
        favoriteOnly: Bool = false,
        phase: CorpusScreenPhase = .ready
    ) -> CorpusState {
        CorpusState(
            phase: phase,
            items: blocks,
            nextCursor: nextCursor,
            searchQuery: searchQuery,
            favoriteOnly: favoriteOnly,
            sceneFilter: sceneFilter,
            functionFilter: functionFilter
        )
    }

    // MARK: - 进步证据

    /// 「开会用上过 N 次」**只在已自动化、且真的用过时**出现。
    ///
    /// 穷举三态 ×（0 次 / 3 次）：一眼能看出它只亮一个格子 —— 而那句话正是稿子说的
    /// 「练了真能用上」的**唯一**证据（PRD §14.3 的数据飞轮在界面上的唯一露出）。
    /// 认不出的状态（`""`）同样不亮：我们不知道它是不是已自动化。
    @Test func 进步证据只在已自动化且真用过时出现() {
        let cases: [(state: String, count: Int, expected: String?)] = [
            ("automated", 3, "开会用上过 3 次"),
            ("automated", 0, nil),
            ("training", 3, nil),
            ("new", 3, nil),
            ("", 3, nil),
        ]

        for (state, count, expected) in cases {
            let model = CorpusProjectionFixture.model(
                blocks: [block(id: "b1", state: state, realUseCount: count)]
            )
            #expect(
                model.rows.first?.realUseNote == expected,
                "状态 \(state.isEmpty ? "认不出" : state) / \(count) 次时，那句话应当是 \(String(describing: expected))，实际 \(String(describing: model.rows.first?.realUseNote))"
            )
        }
    }

    // MARK: - 双维度筛选

    /// 筛选是**取值相等**，不是搜索那套「包含」。
    ///
    /// 这条一开始只放了 `review` / `1on1` / `standup` 三个场景 —— 而它们之间没有子串关系，
    /// 于是「相等」与「包含」**跑出来一模一样**：判据在替错误签字（变异验证会当场发现这一点）。
    /// 真正区分得开的是功能标签里的这一对：`"disagree".contains("agree")` 为真 ——
    /// 拿包含去筛「表示同意」，会把「表示不同意」一起带走，而它们的意思正相反。
    @Test func 筛选是相等而不是包含() {
        let blocks = [
            block(id: "agree", functionTag: "agree"),
            block(id: "disagree", functionTag: "disagree"),
            block(id: "report", functionTag: "report"),
        ]

        #expect(
            state(blocks, functionFilter: "agree").visibleItems.map(\.id) == ["agree"],
            "「表示同意」不能把「表示不同意」也筛进来"
        )
        #expect(
            CorpusProjectionFixture.model(state: state(blocks, functionFilter: "agree"))
                .rows.map(\.id) == ["agree"]
        )

        let scenes = [
            block(id: "a", sceneTag: "review"),
            block(id: "b", sceneTag: "1on1"),
            block(id: "c", sceneTag: "standup"),
        ]
        #expect(CorpusProjectionFixture.model(state: state(scenes, sceneFilter: "review")).rows.map(\.id) == ["a"])
        #expect(state(scenes, sceneFilter: "review").visibleItems.map(\.id) == ["a"], "过滤规则住在 state 上，屏幕读的是它")
    }

    /// 两个维度**同时**生效（AND），各自 `nil` 表示不筛。
    @Test func 两个维度同时生效() {
        let blocks = [
            block(id: "a", sceneTag: "standup", functionTag: "report"),
            block(id: "b", sceneTag: "standup", functionTag: "defer"),
            block(id: "c", sceneTag: "interview", functionTag: "report"),
        ]

        #expect(
            state(blocks, sceneFilter: "standup").visibleItems.map(\.id) == ["a", "b"]
        )
        #expect(
            state(blocks, functionFilter: "report").visibleItems.map(\.id) == ["a", "c"]
        )
        #expect(
            state(blocks, sceneFilter: "standup", functionFilter: "report").visibleItems.map(\.id)
                == ["a"]
        )
        #expect(state(blocks).visibleItems.map(\.id) == ["a", "b", "c"], "都不筛就是全部")
    }

    /// 「有没有在筛」覆盖四个来源 —— 空态要用它决定说哪句话，漏一个就会在筛选时
    /// 显示「完成第一次对话练习」这种莫名其妙的话。
    @Test func 有没有在筛覆盖四个来源() {
        let blocks = [block(id: "a")]

        #expect(state(blocks).hasActiveFilter == false)
        #expect(state(blocks, searchQuery: " ").hasActiveFilter == false, "只有空白不算在筛")
        #expect(state(blocks, searchQuery: "sync").hasActiveFilter)
        #expect(state(blocks, favoriteOnly: true).hasActiveFilter)
        #expect(state(blocks, sceneFilter: "standup").hasActiveFilter)
        #expect(state(blocks, functionFilter: "report").hasActiveFilter)
    }

    // MARK: - 两种空态

    /// **「库里一个都没有」和「筛完是空的」不是同一件事**：前者要去练一次，后者换个条件就有。
    @Test func 两种空态分开() {
        let empty = CorpusProjectionFixture.model(state: state([]))
        #expect(empty.emptyState == .noBlocks)

        let filteredOut = CorpusProjectionFixture.model(
            state: state([block(id: "a", sceneTag: "standup")], sceneFilter: "interview")
        )
        #expect(filteredOut.emptyState == .noMatches)
        #expect(filteredOut.rows.isEmpty)

        let normal = CorpusProjectionFixture.model(state: state([block(id: "a")]))
        #expect(normal.emptyState == nil, "有东西的时候不该有空态")
    }

    /// 还没取完的时候不该说空话：相位不是 `ready` 就不下空态的结论。
    @Test func 未就绪时不下空态的结论() {
        #expect(CorpusProjectionFixture.model(state: state([], phase: .loading)).emptyState == nil)
        #expect(CorpusProjectionFixture.model(state: state([], phase: .failed)).emptyState == nil)
    }

    /// **空语料库走的是 `.idle`，不是 `.loading`。**
    ///
    /// 这条是截图抓出来的：`.remoteLoadSucceeded` 对空快照写的是 `.idle`，而视图一度把
    /// `.idle` 并进了骨架分支 —— 于是「库是空的」这一档永远走不到，屏幕上一直转骨架，
    /// 看起来像没加载完。空态与加载中是两件事：一个要人去练一次，一个只要等。
    @Test func 空语料库在idle档也要给出空态() {
        #expect(
            CorpusProjectionFixture.model(state: state([], phase: .idle)).emptyState == .noBlocks,
            "库里就是空的 —— 这一档必须给出空态，而不是让屏幕停在骨架屏上"
        )
    }

    // MARK: - 计数与标签

    /// 筛选时写成分数：只报一个数的话，学员分不清「库里就这么多」与「筛完剩这么多」。
    @Test func 计数在筛选时是分数() {
        let blocks = [
            block(id: "a", sceneTag: "standup"),
            block(id: "b", sceneTag: "standup"),
            block(id: "c", sceneTag: "interview"),
        ]

        #expect(CorpusProjectionFixture.model(state: state(blocks)).blockCountLabel == "3 个话术块")
        #expect(
            CorpusProjectionFixture.model(state: state(blocks, sceneFilter: "standup"))
                .blockCountLabel == "筛出 2 / 3 个话术块"
        )
    }

    /// 列表没取完时屏幕上要说出来 —— 否则计数与筛选看起来是完整的，其实只覆盖已加载的部分。
    @Test func 列表没取完时要说出来() {
        #expect(CorpusProjectionFixture.model(state: state([block(id: "a")])).showsUnloadedNote == false)
        #expect(
            CorpusProjectionFixture.model(
                state: state([block(id: "a")], nextCursor: "c1")
            ).showsUnloadedNote
        )
    }

    /// 两排 chips 铺满各自的闭集，选中态**最多一个**（不选就是零个）。
    @Test func 两排chips铺满闭集且选中态唯一() {
        let model = CorpusProjectionFixture.model(
            state: state([block(id: "a")], sceneFilter: "review", functionFilter: "defer")
        )

        #expect(model.sceneOptions.map(\.id) == CorpusSceneFilter.allCases.map(\.serverTag))
        #expect(model.functionOptions.map(\.id) == CorpusFunctionFilter.allCases.map(\.serverTag))
        #expect(model.sceneOptions.filter(\.isSelected).map(\.id) == ["review"])
        #expect(model.functionOptions.filter(\.isSelected).map(\.id) == ["defer"])
        #expect(model.sceneOptions.first { $0.id == "review" }?.title == "Design Review")

        let none = CorpusProjectionFixture.model(state: state([block(id: "a")]))
        #expect(none.sceneOptions.filter(\.isSelected).isEmpty)
        #expect(none.functionOptions.filter(\.isSelected).isEmpty)
    }

    /// 服务端给的标签认不出时，**行上不显示那枚标签**（而不是显示 `nil` 或猜一个）。
    ///
    /// 与状态灯同一条纪律。屏幕上少一枚灰签，比多一枚写着错话的签好。
    @Test func 认不出的标签不显示() {
        let model = CorpusProjectionFixture.model(
            state: state(
                [
                    block(id: "a", sceneTag: "standup", functionTag: "report"),
                    block(id: "b", sceneTag: "allhands", functionTag: "report"),
                ]
            )
        )

        #expect(model.rows[0].sceneLabel == "Standup")
        #expect(model.rows[1].sceneLabel == nil, "认不出的场景标签不该被折成某个已知的标签")
        #expect(model.rows[1].functionLabel == "汇报进度", "另一个维度照常显示")
    }
}

/// 一行 fixture：这一份判据里每条都要写 `CorpusViewModel.make(from:)`，包一层省得抄。
private enum CorpusProjectionFixture {
    static func model(state: CorpusState) -> CorpusViewModel {
        CorpusViewModel.make(from: state)
    }

    static func model(blocks: [PhraseBlock]) -> CorpusViewModel {
        CorpusViewModel.make(from: CorpusState(phase: .ready, items: blocks))
    }
}
