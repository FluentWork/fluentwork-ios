import FluentWorkNetworking
import TGReduxKit

public enum CorpusScreenPhase: String, Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed
}

public struct CorpusState: Equatable, Sendable, State {
    public var phase: CorpusScreenPhase
    public var items: [PhraseBlock]
    public var nextCursor: String?
    public var searchQuery: String
    public var favoriteOnly: Bool
    public var isRefreshing: Bool
    public var lastErrorMessage: String?

    public init(
        phase: CorpusScreenPhase = .idle,
        items: [PhraseBlock] = [],
        nextCursor: String? = nil,
        searchQuery: String = "",
        favoriteOnly: Bool = false,
        isRefreshing: Bool = false,
        lastErrorMessage: String? = nil
    ) {
        self.phase = phase
        self.items = items
        self.nextCursor = nextCursor
        self.searchQuery = searchQuery
        self.favoriteOnly = favoriteOnly
        self.isRefreshing = isRefreshing
        self.lastErrorMessage = lastErrorMessage
    }

    public var visibleItems: [PhraseBlock] {
        items.filter { block in
            let matchesFavorite = !favoriteOnly || block.isFavorite
            let keyword = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchesQuery: Bool
            if keyword.isEmpty {
                matchesQuery = true
            } else {
                let lowered = keyword.lowercased()
                matchesQuery =
                    block.intentZH.lowercased().contains(lowered)
                    || block.expressionEN.lowercased().contains(lowered)
                    || block.anchorUserSaid.lowercased().contains(lowered)
                    || block.sceneTag.lowercased().contains(lowered)
                    || block.functionTag.lowercased().contains(lowered)
            }
            return matchesFavorite && matchesQuery
        }
    }
}

public enum CorpusAction: Equatable, Sendable, Action {
    case appear
    case hydrateFromCache(CachedCorpusSnapshot?)
    case refreshRequested
    case loadMoreRequested
    case remoteLoadStarted
    case remoteLoadSucceeded(ListPhraseBlocksResponse, append: Bool)
    case remoteLoadFailed(String)
    case searchQueryChanged(String)
    case favoriteOnlyChanged(Bool)
    case reset
}

public let corpusReducer: Reducer<CorpusState, CorpusAction> = { state, action in
    switch action {
    case .appear:
        if state.items.isEmpty {
            state.phase = .loading
        }
        state.lastErrorMessage = nil

    case let .hydrateFromCache(snapshot):
        guard let snapshot else { break }
        state.items = snapshot.items
        state.nextCursor = snapshot.nextCursor
        state.phase = snapshot.items.isEmpty ? .idle : .ready

    case .refreshRequested, .remoteLoadStarted:
        if state.items.isEmpty {
            state.phase = .loading
        }
        state.isRefreshing = true
        state.lastErrorMessage = nil

    case let .remoteLoadSucceeded(response, append):
        state.isRefreshing = false
        state.phase = .ready
        state.nextCursor = response.nextCursor
        state.lastErrorMessage = nil
        state.items = append
            ? mergeCorpusBlocks(existing: state.items, incoming: response.items)
            : response.items

    case let .remoteLoadFailed(message):
        state.isRefreshing = false
        state.lastErrorMessage = message
        if state.items.isEmpty {
            state.phase = .failed
        }

    case let .searchQueryChanged(query):
        state.searchQuery = query

    case let .favoriteOnlyChanged(favoriteOnly):
        state.favoriteOnly = favoriteOnly

    case .loadMoreRequested:
        break

    case .reset:
        state = CorpusState()
    }
}

private func mergeCorpusBlocks(existing: [PhraseBlock], incoming: [PhraseBlock]) -> [PhraseBlock] {
    var mergedByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
    for block in incoming {
        mergedByID[block.id] = block
    }

    let orderedIDs = existing.map(\.id) + incoming.map(\.id).filter { mergedByID[$0] != nil && !existing.map(\.id).contains($0) }
    var seen = Set<String>()
    return orderedIDs.compactMap { id in
        guard seen.insert(id).inserted else { return nil }
        return mergedByID[id]
    }
}
