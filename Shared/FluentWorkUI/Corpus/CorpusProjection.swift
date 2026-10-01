import FluentWorkCore

extension CorpusViewModel {
    /// State → the corpus screen's plain model.
    ///
    /// The rows come from `state.visibleItems`, **not** from `state.items`: the state already applies
    /// the search box and the favourite filter, and reading the raw list here would put the filter
    /// rule in two places — the one that runs the search and the one that draws the result.
    public static func make(from state: CorpusState) -> CorpusViewModel {
        let phase: CorpusViewPhase
        switch state.phase {
        case .idle:
            phase = .idle
        case .loading:
            phase = .loading
        case .ready:
            phase = .ready
        case .failed:
            phase = .failed
        case .migrating:
            phase = .migrating
        }

        let rows = state.visibleItems.map { block in
            let lamp = CorpusStateLamp(serverState: block.state)
            return CorpusRowViewData(
                id: block.id,
                intentZH: block.intentZH,
                expressionEN: block.expressionEN,
                anchorUserSaid: block.anchorUserSaid,
                sceneTag: block.sceneTag,
                functionTag: block.functionTag,
                sceneLabel: CorpusSceneFilter(serverTag: block.sceneTag)?.label,
                functionLabel: CorpusFunctionFilter(serverTag: block.functionTag)?.label,
                isFavorite: block.isFavorite,
                // 两个「待同步」标记查的是**待办表**，不是块的字段：它们是本地还没落地的
                // 意图，而块本身已经是服务端那一版。
                hasPendingFavorite: state.isPending(blockID: block.id, operation: .favorite),
                hasPendingDelete: state.isPending(blockID: block.id, operation: .delete),
                updatedAt: block.updatedAt,
                // F2：状态灯。认不出的取值 → `nil` → 不画灯（见 `CorpusStateLamp`）。
                lamp: lamp,
                realUseNote: realUseNote(count: block.realUseCount, lamp: lamp)
            )
        }

        return CorpusViewModel(
            phase: phase,
            rows: rows,
            searchQuery: state.searchQuery,
            favoriteOnly: state.favoriteOnly,
            isRefreshing: state.isRefreshing,
            isReplayingOutbox: state.isReplayingOutbox,
            canLoadMore: state.nextCursor != nil,
            errorMessage: state.lastErrorMessage,
            blockCountLabel: blockCountLabel(
                visible: rows.count,
                loaded: state.items.count,
                isFiltering: state.hasActiveFilter
            ),
            showsUnloadedNote: state.nextCursor != nil,
            sceneOptions: sceneChips(selected: state.sceneFilter),
            functionOptions: functionChips(selected: state.functionFilter),
            emptyState: emptyState(
                phase: state.phase,
                loadedCount: state.items.count,
                visibleCount: rows.count
            )
        )
    }

    /// 「开会用上过 N 次」——**只在已自动化的块上、且真的用过时**才给。
    ///
    /// 这是稿子说的那条「进步证据」（`real_use_count`，PRD §14.3 的数据飞轮在界面上唯一的露出）。
    /// 两道门都是必要的：
    ///
    /// - **没自动化就不显示**：一个还在训练中的块本来就用不上，给它挂一句「开会用上过 0 次」
    ///   是在提醒失败，不是在展示进步；
    /// - **0 次不显示**：`realUseCount == 0` 的话，这句话什么也没证明。
    ///
    /// `lamp == nil`（认不出的状态）同样不显示：我们不知道它是不是已自动化。
    private static func realUseNote(count: Int, lamp: CorpusStateLamp?) -> String? {
        guard lamp == .automated, count > 0 else { return nil }
        return "开会用上过 \(count) 次"
    }

    /// 标题旁那一行计数。
    ///
    /// 筛选时写成分数「筛出 3 / 24」：只报一个数的话，学员分不清「库里就这么多」
    /// 与「筛完剩这么多」——而那两件事要做的事情完全不同。
    private static func blockCountLabel(visible: Int, loaded: Int, isFiltering: Bool) -> String {
        isFiltering
            ? "筛出 \(visible) / \(loaded) 个话术块"
            : "\(loaded) 个话术块"
    }

    /// 两个维度各铺一排 chips。
    ///
    /// 「点已选中的那一个」＝ 取消这一维的筛选（`selected == nil` 落回全不选），
    /// 所以这里只负责把「选没选中」算出来，取消的语义在 reducer 里。
    private static func sceneChips(selected: String?) -> [CorpusViewModel.FilterChip] {
        CorpusSceneFilter.allCases.map { scene in
            CorpusViewModel.FilterChip(
                id: scene.serverTag,
                title: scene.label,
                isSelected: selected == scene.serverTag
            )
        }
    }

    private static func functionChips(selected: String?) -> [CorpusViewModel.FilterChip] {
        CorpusFunctionFilter.allCases.map { function in
            CorpusViewModel.FilterChip(
                id: function.serverTag,
                title: function.label,
                isSelected: selected == function.serverTag
            )
        }
    }

    private static func emptyState(
        phase: CorpusScreenPhase,
        loadedCount: Int,
        visibleCount: Int
    ) -> CorpusViewModel.EmptyState? {
        // `.idle` 也算数：它是「服务端回过一次、库里就是空的」（见 `.remoteLoadSucceeded`
        // 对空快照的处理）。把它排除在外的话，空语料库会永远停在骨架屏上。
        guard phase == .ready || phase == .idle else { return nil }
        if loadedCount == 0 {
            return .noBlocks
        }
        return visibleCount == 0 ? .noMatches : nil
    }
}
