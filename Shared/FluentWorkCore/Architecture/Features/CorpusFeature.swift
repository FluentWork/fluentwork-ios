import FluentWorkNetworking
import TGReduxKit

public enum CorpusScreenPhase: String, Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed
    case migrating
}

public struct CorpusPendingIndicator: Equatable, Sendable {
    public var blockID: String
    public var operation: CorpusOutboxOperation

    public init(blockID: String, operation: CorpusOutboxOperation) {
        self.blockID = blockID
        self.operation = operation
    }
}

public struct CorpusState: Equatable, Sendable, State {
    public var phase: CorpusScreenPhase
    public var items: [PhraseBlock]
    public var nextCursor: String?
    public var syncCursor: String?
    public var searchQuery: String
    public var favoriteOnly: Bool
    public var isRefreshing: Bool
    public var isReplayingOutbox: Bool
    public var pendingIndicators: [CorpusPendingIndicator]
    public var outbox: [CorpusOutboxItem]
    public var hasHydratedCache: Bool
    public var hasHydratedSyncMetadata: Bool
    public var didRequestInitialRefresh: Bool
    public var lastErrorMessage: String?

    public init(
        phase: CorpusScreenPhase = .idle,
        items: [PhraseBlock] = [],
        nextCursor: String? = nil,
        syncCursor: String? = nil,
        searchQuery: String = "",
        favoriteOnly: Bool = false,
        isRefreshing: Bool = false,
        isReplayingOutbox: Bool = false,
        pendingIndicators: [CorpusPendingIndicator] = [],
        outbox: [CorpusOutboxItem] = [],
        hasHydratedCache: Bool = false,
        hasHydratedSyncMetadata: Bool = false,
        didRequestInitialRefresh: Bool = false,
        lastErrorMessage: String? = nil
    ) {
        self.phase = phase
        self.items = items
        self.nextCursor = nextCursor
        self.syncCursor = syncCursor
        self.searchQuery = searchQuery
        self.favoriteOnly = favoriteOnly
        self.isRefreshing = isRefreshing
        self.isReplayingOutbox = isReplayingOutbox
        self.pendingIndicators = pendingIndicators
        self.outbox = outbox
        self.hasHydratedCache = hasHydratedCache
        self.hasHydratedSyncMetadata = hasHydratedSyncMetadata
        self.didRequestInitialRefresh = didRequestInitialRefresh
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

    public func isPending(blockID: String, operation: CorpusOutboxOperation) -> Bool {
        pendingIndicators.contains { $0.blockID == blockID && $0.operation == operation }
    }
}

public enum CorpusAction: Equatable, Sendable, Action {
    case appear
    case hydrateFromCache(CachedCorpusSnapshot?)
    case hydrateOutbox([CorpusOutboxItem])
    case hydrateSyncMetadata(CorpusSyncMetadata?)
    case initialRefreshTriggered
    case refreshRequested
    case loadMoreRequested
    case remoteLoadStarted
    case remoteLoadSucceeded(snapshot: CachedCorpusSnapshot, metadata: CorpusSyncMetadata)
    case remoteLoadFailed(String)
    case favoriteToggled(blockID: String, isFavorite: Bool, pinned: Bool)
    case deleteTapped(blockID: String)
    case enqueueOutboxItem(CorpusOutboxItem)
    case removeOutboxItem(id: String)
    case outboxReplayStarted
    case outboxReplayCompleted(ids: [String])
    case outboxReplayFinished
    case outboxReplayFailed(String)
    case mergeRebuildStarted
    case mergeRebuildPrepared(snapshot: CachedCorpusSnapshot, metadata: CorpusSyncMetadata)
    case mergeRebuildFinished
    case searchQueryChanged(String)
    case favoriteOnlyChanged(Bool)
    case reset
}

public let corpusReducer: Reducer<CorpusState, CorpusAction> = { state, action in
    switch action {
    case .appear:
        state.hasHydratedCache = false
        state.hasHydratedSyncMetadata = false
        state.didRequestInitialRefresh = false
        if state.items.isEmpty {
            state.phase = .loading
        }
        state.lastErrorMessage = nil

    case let .hydrateFromCache(snapshot):
        state.hasHydratedCache = true
        guard let snapshot else { break }
        state.items = snapshot.items
        state.nextCursor = snapshot.nextCursor
        state.phase = snapshot.items.isEmpty ? .idle : .ready

    case let .hydrateOutbox(items):
        state.outbox = items
        state.pendingIndicators = items.map {
            CorpusPendingIndicator(blockID: $0.blockID, operation: $0.operation)
        }

    case let .hydrateSyncMetadata(metadata):
        state.hasHydratedSyncMetadata = true
        state.nextCursor = metadata?.listCursor ?? state.nextCursor
        state.syncCursor = metadata?.syncCursor

    case .initialRefreshTriggered:
        state.didRequestInitialRefresh = true

    case .refreshRequested, .remoteLoadStarted:
        if state.items.isEmpty {
            state.phase = .loading
        }
        state.isRefreshing = true
        state.lastErrorMessage = nil

    case let .remoteLoadSucceeded(snapshot, metadata):
        state.isRefreshing = false
        state.phase = snapshot.items.isEmpty ? .idle : .ready
        state.items = snapshot.items
        state.nextCursor = metadata.listCursor
        state.syncCursor = metadata.syncCursor
        state.lastErrorMessage = nil

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

    case let .favoriteToggled(blockID, isFavorite, _):
        updateCorpusBlock(withID: blockID, in: &state.items) { block in
            block.isFavorite = isFavorite
            if !isFavorite {
                block.pinnedAt = nil
            }
        }

    case let .deleteTapped(blockID):
        state.items.removeAll { $0.id == blockID }
        state.pendingIndicators.append(
            CorpusPendingIndicator(blockID: blockID, operation: .delete)
        )

    case let .enqueueOutboxItem(item):
        state.outbox.removeAll { $0.blockID == item.blockID && $0.operation == item.operation }
        state.outbox.append(item)
        if !state.isPending(blockID: item.blockID, operation: item.operation) {
            state.pendingIndicators.append(
                CorpusPendingIndicator(blockID: item.blockID, operation: item.operation)
            )
        }

    case let .removeOutboxItem(id):
        if let item = state.outbox.first(where: { $0.id == id }) {
            state.pendingIndicators.removeAll {
                $0.blockID == item.blockID && $0.operation == item.operation
            }
        }
        state.outbox.removeAll { $0.id == id }

    case .outboxReplayStarted:
        state.isReplayingOutbox = true
        state.lastErrorMessage = nil

    case let .outboxReplayCompleted(ids):
        for id in ids {
            if let item = state.outbox.first(where: { $0.id == id }) {
                state.pendingIndicators.removeAll {
                    $0.blockID == item.blockID && $0.operation == item.operation
                }
            }
        }
        state.outbox.removeAll { ids.contains($0.id) }
        state.isReplayingOutbox = false

    case .outboxReplayFinished:
        state.isReplayingOutbox = false

    case let .outboxReplayFailed(message):
        state.isReplayingOutbox = false
        state.lastErrorMessage = message

    case .mergeRebuildStarted:
        state.phase = .migrating
        state.isRefreshing = true
        state.lastErrorMessage = nil

    case let .mergeRebuildPrepared(snapshot, metadata):
        state.items = snapshot.items
        state.nextCursor = metadata.listCursor
        state.syncCursor = metadata.syncCursor
        state.outbox = []
        state.pendingIndicators = []
        state.phase = snapshot.items.isEmpty ? .idle : .ready
        state.isRefreshing = false

    case .mergeRebuildFinished:
        state.phase = state.items.isEmpty ? .idle : .ready
        state.isRefreshing = false

    case .loadMoreRequested:
        break

    case .reset:
        state = CorpusState()
    }
}

private func updateCorpusBlock(
    withID blockID: String,
    in items: inout [PhraseBlock],
    mutate: (inout PhraseBlock) -> Void
) {
    guard let index = items.firstIndex(where: { $0.id == blockID }) else {
        return
    }
    mutate(&items[index])
}
