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

        return CorpusViewModel(
            phase: phase,
            rows: state.visibleItems.map { block in
                CorpusRowViewData(
                    id: block.id,
                    intentZH: block.intentZH,
                    expressionEN: block.expressionEN,
                    anchorUserSaid: block.anchorUserSaid,
                    sceneTag: block.sceneTag,
                    functionTag: block.functionTag,
                    isFavorite: block.isFavorite,
                    // 两个「待同步」标记查的是**待办表**，不是块的字段：它们是本地还没落地的
                    // 意图，而块本身已经是服务端那一版。
                    hasPendingFavorite: state.isPending(blockID: block.id, operation: .favorite),
                    hasPendingDelete: state.isPending(blockID: block.id, operation: .delete),
                    updatedAt: block.updatedAt,
                    // F2：状态灯。认不出的取值 → `nil` → 不画灯（见 `CorpusStateLamp`）。
                    lamp: CorpusStateLamp(serverState: block.state)
                )
            },
            searchQuery: state.searchQuery,
            favoriteOnly: state.favoriteOnly,
            isRefreshing: state.isRefreshing,
            isReplayingOutbox: state.isReplayingOutbox,
            canLoadMore: state.nextCursor != nil,
            errorMessage: state.lastErrorMessage
        )
    }
}
