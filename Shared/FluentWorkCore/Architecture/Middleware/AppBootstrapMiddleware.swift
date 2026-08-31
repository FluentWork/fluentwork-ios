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
                }
            )

        case .corpus(.hydrateFromCache):
            return .merge(
                next(action),
                .task {
                    .corpus(.refreshRequested)
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
                        try await corpusCacheStore.saveSnapshot(
                            CachedCorpusSnapshot(items: response.items, nextCursor: response.nextCursor),
                            scope: scope
                        )
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
                        try await corpusCacheStore.saveSnapshot(
                            CachedCorpusSnapshot(items: merged, nextCursor: response.nextCursor),
                            scope: scope
                        )
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
