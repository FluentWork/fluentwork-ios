import FactoryKit
import FluentWorkNetworking
import Foundation
import TGReduxKit

public enum AppTaskID {
    public static let bootstrap: CancellationID = "app.bootstrap"
    public static let networkMonitor: CancellationID = "app.networkMonitor"
    public static let reviewPoll: CancellationID = "review.poll"
    public static let corpusHydrate: CancellationID = "corpus.hydrate"
    public static let corpusRefresh: CancellationID = "corpus.refresh"
    public static let corpusLoadMore: CancellationID = "corpus.load-more"
    public static let corpusReplayOutbox: CancellationID = "corpus.replay-outbox"
    public static let corpusMergeRebuild: CancellationID = "corpus.merge-rebuild"

    public static func reviewAccept(cardID: String) -> CancellationID {
        CancellationID("review.accept.\(cardID)")
    }
}

public func makeAppMiddlewares(container: Container? = nil) -> [Middleware<AppState, AppAction>] {
    let resolvedContainer = container ?? Container.shared
    return [
        corpusMiddleware(container: resolvedContainer),
        reviewMiddleware(container: resolvedContainer),
        speechSessionMiddleware(container: resolvedContainer),
        appBootstrapMiddleware(container: resolvedContainer),
        appNetworkMonitorMiddleware(container: resolvedContainer),
    ]
}

public func appBootstrapMiddleware(container: Container? = nil) -> Middleware<AppState, AppAction> {
    let resolvedContainer = container ?? Container.shared

    return { store, action, next in
        guard case .lifecycle(.appLaunched) = action else {
            return next(action)
        }
        guard store.state.bootstrapStatus != .loading else {
            return next(action)
        }

        let bootstrapClient = resolvedContainer.bootstrapClient()
        let base = next(action)

        return .merge(
            base,
            .task(id: AppTaskID.bootstrap) {
                do {
                    let snapshot = try await bootstrapClient.loadBootstrap()
                    guard !Task.isCancelled else { return nil }
                    return .lifecycle(.bootstrapSucceeded(snapshot))
                } catch is CancellationError {
                    return nil
                } catch {
                    guard !Task.isCancelled else { return nil }
                    return .lifecycle(.bootstrapFailed(appBootstrapErrorMessage(error)))
                }
            }
        )
    }
}

public func appNetworkMonitorMiddleware(container: Container? = nil) -> Middleware<AppState, AppAction> {
    let resolvedContainer = container ?? Container.shared

    return { store, action, next in
        guard case .lifecycle(.appLaunched) = action else {
            return next(action)
        }

        let monitor = resolvedContainer.networkMonitor()
        let initial = monitor.currentSnapshot()
        let base = next(action)
        let dispatchBox = MainActorDispatchBox(dispatch: { store.dispatch($0) })

        return .merge(
            base,
            .task {
                .network(.connectivityChanged(initial))
            },
            .task(id: AppTaskID.networkMonitor) {
                for await snapshot in monitor.connectivityUpdates() {
                    guard !Task.isCancelled else { return nil }
                    await dispatchBox.dispatch(.network(.connectivityChanged(snapshot)))
                }
                return nil
            }
        )
    }
}

/// Bridges `@MainActor` store dispatch into a `@Sendable` Effect task.
private final class MainActorDispatchBox: @unchecked Sendable {
    private let dispatch: @MainActor (AppAction) -> Void

    init(dispatch: @escaping @MainActor (AppAction) -> Void) {
        self.dispatch = dispatch
    }

    func dispatch(_ action: AppAction) async {
        await dispatch(action)
    }
}

private func appBootstrapErrorMessage(_ error: any Error) -> String {
    if let localized = error as? any LocalizedError,
       let description = localized.errorDescription,
       !description.isEmpty {
        return description
    }

    return "Bootstrap failed. Please try again."
}

public func reviewMiddleware(container: Container? = nil) -> Middleware<AppState, AppAction> {
    let resolvedContainer = container ?? Container.shared

    return { store, action, next in
        let speechClient = resolvedContainer.speechSessionClient()
        let corpusClient = resolvedContainer.corpusClient()

        switch action {
        case let .review(.appear(sessionID)):
            guard let sessionID, !sessionID.isEmpty else {
                return next(action)
            }
            return .merge(
                next(action),
                .task {
                    .review(.loadRequested(sessionID: sessionID))
                }
            )

        case let .review(.loadRequested(sessionID)):
            let base = next(action)
            return .merge(
                base,
                .task(id: AppTaskID.reviewPoll) {
                    do {
                        let poll = try await speechClient.pollReview(sessionID: sessionID)
                        guard !Task.isCancelled else { return nil }
                        return .review(.applyPoll(poll))
                    } catch is CancellationError {
                        return nil
                    } catch {
                        guard !Task.isCancelled else { return nil }
                        return .review(.loadFailed(error.localizedDescription))
                    }
                }
            )

        case let .review(.acceptRefineCardTapped(cardID)):
            guard let sessionID = store.state.review.sessionID,
                  !sessionID.isEmpty,
                  let payload = store.state.review.payload,
                  let card = payload.refineCards.first(where: { $0.id == cardID }),
                  !store.state.review.acceptingRefineCardIDs.contains(cardID),
                  !store.state.review.acceptedRefineCardIDs.contains(cardID)
            else {
                return next(action)
            }

            let base = next(action)
            return .merge(
                base,
                .task {
                    .review(.acceptRefineCardStarted(cardID: cardID))
                },
                .task(id: AppTaskID.reviewAccept(cardID: cardID)) {
                    do {
                        let response = try await corpusClient.batchAccept(
                            sourceSessionID: sessionID,
                            cards: [card]
                        )
                        guard !Task.isCancelled else { return nil }
                        return .review(
                            .acceptRefineCardSucceeded(
                                cardID: cardID,
                                acceptedCount: response.acceptedCount
                            )
                        )
                    } catch is CancellationError {
                        return nil
                    } catch {
                        guard !Task.isCancelled else { return nil }
                        return .review(
                            .acceptRefineCardFailed(
                                cardID: cardID,
                                message: error.localizedDescription
                            )
                        )
                    }
                }
            )

        default:
            return next(action)
        }
    }
}

public func corpusMiddleware(container: Container? = nil) -> Middleware<AppState, AppAction> {
    let resolvedContainer = container ?? Container.shared
    let corpusClient = resolvedContainer.corpusClient()
    let corpusCacheStore = resolvedContainer.corpusCacheStore()
    let corpusOutboxStore = resolvedContainer.corpusOutboxStore()
    let corpusSyncMetadataStore = resolvedContainer.corpusSyncMetadataStore()
    let idGenerator = resolvedContainer.idGenerator()
    let clock = resolvedContainer.clock()

    return { store, action, next in
        switch action {
        case .corpus(.appear):
            let scope = corpusCacheScope(for: store.state)
            return .merge(
                next(action),
                .task(id: AppTaskID.corpusHydrate) {
                    do {
                        let snapshot = try await corpusCacheStore.loadSnapshot(scope: scope)
                        guard !Task.isCancelled else { return nil }
                        return .corpus(.hydrateFromCache(snapshot))
                    } catch is CancellationError {
                        return nil
                    } catch {
                        guard !Task.isCancelled else { return nil }
                        return .corpus(.hydrateFromCache(nil))
                    }
                },
                .task {
                    do {
                        let outbox = try await corpusOutboxStore.loadItems(scope: scope)
                        return .corpus(.hydrateOutbox(outbox))
                    } catch is CancellationError {
                        return nil
                    } catch {
                        return .corpus(.hydrateOutbox([]))
                    }
                },
                .task {
                    do {
                        let syncMetadata = try await corpusSyncMetadataStore.load(scope: scope)
                        return .corpus(.hydrateSyncMetadata(syncMetadata))
                    } catch is CancellationError {
                        return nil
                    } catch {
                        return .corpus(.hydrateSyncMetadata(nil))
                    }
                }
            )

        case .corpus(.hydrateFromCache):
            let effects: [Effect<AppAction>] = [
                next(action),
                .task {
                    .corpus(.refreshRequested)
                },
            ]
            return .merge(effects)

        case .corpus(.hydrateOutbox(let items)):
            guard store.state.network.isConnected, !items.isEmpty else {
                return next(action)
            }
            return .merge(
                next(action),
                .task {
                    .corpus(.outboxReplayStarted)
                }
            )

        case .corpus(.refreshRequested):
            let scope = corpusCacheScope(for: store.state)
            let base = next(action)
            return .merge(
                base,
                .task(id: AppTaskID.corpusRefresh) {
                    do {
                        let response = try await corpusClient.listBlocks(
                            cursor: nil,
                            limit: 50,
                            favoriteOnly: false
                        )
                        let syncCursor = response.items.map(\.updatedAt).max()
                        let snapshot = CachedCorpusSnapshot(items: response.items, nextCursor: response.nextCursor)
                        let metadata = CorpusSyncMetadata(
                            listCursor: response.nextCursor,
                            syncCursor: syncCursor
                        )
                        try await corpusCacheStore.saveSnapshot(snapshot, scope: scope)
                        try await corpusSyncMetadataStore.save(metadata, scope: scope)
                        guard !Task.isCancelled else { return nil }
                        return .corpus(.remoteLoadSucceeded(response, append: false))
                    } catch is CancellationError {
                        return nil
                    } catch {
                        guard !Task.isCancelled else { return nil }
                        return .corpus(.remoteLoadFailed(error.localizedDescription))
                    }
                }
            )

        case .corpus(.loadMoreRequested):
            guard !store.state.corpus.isRefreshing,
                  let cursor = store.state.corpus.nextCursor,
                  !cursor.isEmpty
            else {
                return next(action)
            }
            let scope = corpusCacheScope(for: store.state)
            let currentItems = store.state.corpus.items
            let currentSyncCursor = store.state.corpus.syncCursor
            let base = next(action)
            return .merge(
                base,
                .task {
                    .corpus(.remoteLoadStarted)
                },
                .task(id: AppTaskID.corpusLoadMore) {
                    do {
                        let response = try await corpusClient.listBlocks(
                            cursor: cursor,
                            limit: 50,
                            favoriteOnly: false
                        )
                        let merged = mergeCachedSnapshot(
                            currentItems: currentItems,
                            incoming: response.items
                        )
                        let metadata = CorpusSyncMetadata(
                            listCursor: response.nextCursor,
                            syncCursor: max(
                                currentSyncCursor ?? "",
                                response.items.map(\.updatedAt).max() ?? ""
                            ).nilIfEmpty
                        )
                        try await corpusCacheStore.saveSnapshot(
                            CachedCorpusSnapshot(items: merged, nextCursor: response.nextCursor),
                            scope: scope
                        )
                        try await corpusSyncMetadataStore.save(metadata, scope: scope)
                        guard !Task.isCancelled else { return nil }
                        return .corpus(.remoteLoadSucceeded(response, append: true))
                    } catch is CancellationError {
                        return nil
                    } catch {
                        guard !Task.isCancelled else { return nil }
                        return .corpus(.remoteLoadFailed(error.localizedDescription))
                    }
                }
            )

        case let .corpus(.favoriteToggled(blockID, isFavorite, pinned)):
            guard !store.state.network.isConnected else {
                let scope = corpusCacheScope(for: store.state)
                let currentItems = store.state.corpus.items
                let currentNextCursor = store.state.corpus.nextCursor
                let base = next(action)
                return .merge(
                    base,
                    .task(id: CancellationID("corpus.favorite.\(blockID)")) {
                        do {
                            let updated = try await corpusClient.setFavorite(
                                blockID: blockID,
                                isFavorite: isFavorite,
                                pinned: pinned
                            )
                            let items = replaceCorpusBlock(currentItems, with: updated)
                            try await corpusCacheStore.saveSnapshot(
                                CachedCorpusSnapshot(
                                    items: items,
                                    nextCursor: currentNextCursor
                                ),
                                scope: scope
                            )
                            return .corpus(.refreshRequested)
                        } catch {
                            return .corpus(.outboxReplayFailed(error.localizedDescription))
                        }
                    }
                )
            }

            let item = CorpusOutboxItem(
                id: idGenerator.uuid().uuidString,
                blockID: blockID,
                operation: .favorite,
                payload: .init(isFavorite: isFavorite, pinned: pinned),
                retryCount: 0,
                createdAt: iso8601String(from: clock.now())
            )
            let scope = corpusCacheScope(for: store.state)
            let existing = store.state.corpus.outbox
            return .merge(
                next(action),
                .task {
                    do {
                        let updated = upsertOutboxItem(item, existing: existing)
                        try await corpusOutboxStore.saveItems(updated, scope: scope)
                        return .corpus(.enqueueOutboxItem(item))
                    } catch is CancellationError {
                        return nil
                    } catch {
                        return .corpus(.outboxReplayFailed(error.localizedDescription))
                    }
                }
            )

        case let .corpus(.deleteTapped(blockID)):
            guard !store.state.network.isConnected else {
                let scope = corpusCacheScope(for: store.state)
                let items = store.state.corpus.items.filter { $0.id != blockID }
                let currentNextCursor = store.state.corpus.nextCursor
                let base = next(action)
                return .merge(
                    base,
                    .task(id: CancellationID("corpus.delete.\(blockID)")) {
                        do {
                            try await corpusClient.deleteBlock(blockID: blockID)
                            try await corpusCacheStore.saveSnapshot(
                                CachedCorpusSnapshot(items: items, nextCursor: currentNextCursor),
                                scope: scope
                            )
                            return .corpus(.refreshRequested)
                        } catch {
                            return .corpus(.outboxReplayFailed(error.localizedDescription))
                        }
                    }
                )
            }

            let item = CorpusOutboxItem(
                id: idGenerator.uuid().uuidString,
                blockID: blockID,
                operation: .delete,
                payload: .init(),
                retryCount: 0,
                createdAt: iso8601String(from: clock.now())
            )
            let scope = corpusCacheScope(for: store.state)
            let remainingItems = store.state.corpus.items.filter { $0.id != blockID }
            let existing = store.state.corpus.outbox
            let currentNextCursor = store.state.corpus.nextCursor
            return .merge(
                next(action),
                .task {
                    do {
                        let updated = upsertOutboxItem(item, existing: existing)
                        try await corpusOutboxStore.saveItems(updated, scope: scope)
                        try await corpusCacheStore.saveSnapshot(
                            CachedCorpusSnapshot(items: remainingItems, nextCursor: currentNextCursor),
                            scope: scope
                        )
                        return .corpus(.enqueueOutboxItem(item))
                    } catch is CancellationError {
                        return nil
                    } catch {
                        return .corpus(.outboxReplayFailed(error.localizedDescription))
                    }
                }
            )

        case .corpus(.outboxReplayStarted):
            guard store.state.network.isConnected, !store.state.corpus.outbox.isEmpty else {
                return next(action)
            }
            let scope = corpusCacheScope(for: store.state)
            let pendingItems = store.state.corpus.outbox
            let base = next(action)
            return .merge(
                base,
                .task(id: AppTaskID.corpusReplayOutbox) {
                    do {
                        for item in pendingItems {
                            switch item.operation {
                            case .favorite:
                                _ = try await corpusClient.setFavorite(
                                    blockID: item.blockID,
                                    isFavorite: item.payload.isFavorite ?? false,
                                    pinned: item.payload.pinned ?? false
                                )
                            case .delete:
                                try await corpusClient.deleteBlock(blockID: item.blockID)
                            }
                        }
                        try await corpusOutboxStore.clearItems(scope: scope)
                        return .corpus(.outboxReplayCompleted(ids: pendingItems.map(\.id)))
                    } catch is CancellationError {
                        return nil
                    } catch {
                        return .corpus(.outboxReplayFailed(error.localizedDescription))
                    }
                }
            )

        case .corpus(.outboxReplayCompleted):
            return .merge(
                next(action),
                .task {
                    .corpus(.refreshRequested)
                }
            )

        case .network(.connectivityChanged(let snapshot)):
            guard snapshot.isConnected, !store.state.corpus.outbox.isEmpty else {
                return next(action)
            }
            return .merge(
                next(action),
                .task {
                    .corpus(.outboxReplayStarted)
                }
            )

        case .auth(.mergedIntoRegistered):
            let oldScope = corpusCacheScope(for: store.state)
            let newScope = mergeTargetCorpusScope(for: action, fallbackState: store.state)
            guard oldScope != newScope else {
                return next(action)
            }
            let base = next(action)
            return .merge(
                base,
                .task {
                    .corpus(.mergeRebuildStarted)
                },
                .task(id: AppTaskID.corpusMergeRebuild) {
                    do {
                        try await corpusCacheStore.clearSnapshot(scope: oldScope)
                        try await corpusOutboxStore.clearItems(scope: oldScope)
                        try await corpusSyncMetadataStore.clear(scope: oldScope)
                        let response = try await corpusClient.listBlocks(
                            cursor: nil,
                            limit: 50,
                            favoriteOnly: false
                        )
                        try await corpusCacheStore.saveSnapshot(
                            CachedCorpusSnapshot(items: response.items, nextCursor: response.nextCursor),
                            scope: newScope
                        )
                        try await corpusSyncMetadataStore.save(
                            CorpusSyncMetadata(
                                listCursor: response.nextCursor,
                                syncCursor: response.items.map(\.updatedAt).max()
                            ),
                            scope: newScope
                        )
                        return .corpus(.mergeRebuildPrepared(
                            snapshot: CachedCorpusSnapshot(
                                items: response.items,
                                nextCursor: response.nextCursor
                            ),
                            metadata: CorpusSyncMetadata(
                                listCursor: response.nextCursor,
                                syncCursor: response.items.map(\.updatedAt).max()
                            )
                        ))
                    } catch {
                        return .corpus(.remoteLoadFailed(error.localizedDescription))
                    }
                }
            )

        case .corpus(.mergeRebuildPrepared):
            return .merge(
                next(action),
                .task {
                    .corpus(.mergeRebuildFinished)
                }
            )

        default:
            return next(action)
        }
    }
}

private func corpusCacheScope(for state: AppState) -> String {
    state.auth.currentUserID ?? state.auth.mode.rawValue
}

private func mergeCachedSnapshot(currentItems: [PhraseBlock], incoming: [PhraseBlock]) -> [PhraseBlock] {
    var mergedByID = Dictionary(uniqueKeysWithValues: currentItems.map { ($0.id, $0) })
    for block in incoming {
        mergedByID[block.id] = block
    }

    var ordered = currentItems.map(\.id)
    for id in incoming.map(\.id) where !ordered.contains(id) {
        ordered.append(id)
    }

    return ordered.compactMap { mergedByID[$0] }
}

private func replaceCorpusBlock(_ items: [PhraseBlock], with updated: PhraseBlock) -> [PhraseBlock] {
    var result = items
    if let index = result.firstIndex(where: { $0.id == updated.id }) {
        result[index] = updated
    } else {
        result.insert(updated, at: 0)
    }
    return result
}

private func upsertOutboxItem(_ item: CorpusOutboxItem, existing: [CorpusOutboxItem]) -> [CorpusOutboxItem] {
    var filtered = existing.filter {
        !($0.blockID == item.blockID && $0.operation == item.operation)
    }
    filtered.append(item)
    return filtered.sorted { $0.createdAt < $1.createdAt }
}

private func iso8601String(from date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}

private func mergeTargetCorpusScope(for action: AppAction, fallbackState: AppState) -> String {
    guard case let .auth(.mergedIntoRegistered(userID, _)) = action else {
        return corpusCacheScope(for: fallbackState)
    }
    return userID
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
