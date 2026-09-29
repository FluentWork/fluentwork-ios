import FactoryKit
import FluentWorkNetworking
import Foundation
import TGReduxKit

/// Bridges `SessionHistoryAction` to `GET /api/v1/sessions`.
///
/// Thinner than `corpusMiddleware`, deliberately: this list is **read-only**, and
/// it has no outbox, no tombstone and no merge rebuild. Sessions live in
/// `practice_sessions`; the client never edits one, so there is nothing local to
/// reconcile with the server and a client-side copy would be a second source of
/// truth for something the user cannot change (`79_` §设计 1).
///
/// The cache it *does* have is a **display** cache, which is a different thing:
/// it holds the last page that was on screen so walking into this screen on a
/// weak network shows that page instead of a blank one (稿子 §07 场景 06). It is
/// read-through only — the screen never writes through it, and losing it costs
/// nothing but the next round trip.
public func sessionHistoryMiddleware(container: Container) -> Middleware<AppState, AppAction> {
    let client = container.sessionHistoryClient()
    let cacheStore = container.sessionHistoryCacheStore()

    return { store, action, next in
        guard case .sessionHistory(let historyAction) = action else {
            return next(action)
        }

        switch historyAction {
        case .appear, .refreshRequested:
            let scope = cacheScope(for: store.state)
            let base = next(action)
            return .merge(
                base,
                .task(id: AppTaskID.sessionHistoryHydrate) {
                    await hydrateFromCache(cacheStore: cacheStore, scope: scope)
                },
                .task(id: AppTaskID.sessionHistoryLoad) {
                    // Page one, replacing. `appending: false` is what makes a
                    // refresh drop rows that were paged in — correct here:
                    // those rows are the *older* ones, still on the server, and
                    // the user can page to them again.
                    await loadSessions(
                        client: client,
                        cacheStore: cacheStore,
                        scope: scope,
                        currentItems: [],
                        cursor: nil,
                        appending: false
                    )
                }
            )

        case .loadMoreRequested:
            // Same shape as `corpusMiddleware`: guard on pre-state so a second
            // tap during an in-flight page is a no-op rather than a second
            // request for the same cursor.
            guard !store.state.sessionHistory.isLoadingMore,
                let cursor = store.state.sessionHistory.nextCursor,
                !cursor.isEmpty
            else {
                return next(action)
            }
            let scope = cacheScope(for: store.state)
            let currentItems = store.state.sessionHistory.items
            let base = next(action)
            return .merge(
                base,
                .task(id: AppTaskID.sessionHistoryLoadMore) {
                    await loadSessions(
                        client: client,
                        cacheStore: cacheStore,
                        scope: scope,
                        currentItems: currentItems,
                        cursor: cursor,
                        appending: true
                    )
                }
            )

        case .detailRequested(let sessionID):
            let base = next(action)
            return .merge(
                base,
                // One task id for every session, so opening B cancels A's
                // request instead of racing it. The reducer's
                // `requestedSessionID` check would catch that race anyway; this
                // is what stops the wasted round trip and the late write.
                .task(id: AppTaskID.sessionHistoryDetail) {
                    await loadDetail(client: client, sessionID: sessionID)
                }
            )

        case .hydrateFromCache, .loadSucceeded, .loadFailed, .detailSucceeded, .detailFailed:
            return next(action)
        }
    }
}

private func hydrateFromCache(
    cacheStore: SessionHistoryCacheStoreProtocol,
    scope: String
) async -> AppAction? {
    do {
        let snapshot = try await cacheStore.loadSnapshot(scope: scope)
        guard !Task.isCancelled else { return nil }
        return .sessionHistory(.hydrateFromCache(snapshot))
    } catch is CancellationError {
        return nil
    } catch {
        guard !Task.isCancelled else { return nil }
        return .sessionHistory(.hydrateFromCache(nil))
    }
}

private func loadDetail(
    client: SessionHistoryClientProtocol,
    sessionID: String
) async -> AppAction? {
    do {
        let detail = try await client.sessionDetail(sessionID: sessionID)
        guard !Task.isCancelled else { return nil }
        return .sessionHistory(.detailSucceeded(detail))
    } catch is CancellationError {
        return nil
    } catch {
        guard !Task.isCancelled else { return nil }
        return .sessionHistory(.detailFailed(error.localizedDescription))
    }
}

/// One page, one action back.
///
/// Returns `AppAction?` rather than dispatching directly so the call sits in
/// the same `.task` shape as every other middleware here — and so cancellation
/// (task id reuse, a cancelled `.task`) drops the result instead of writing a
/// stale page over a newer one.
///
/// The snapshot is saved **inside** this task, before the success action goes
/// back, the way `corpusMiddleware` does it — so what gets stored is what is
/// about to be on screen, not whatever the state happens to hold later.
/// `appending` is why the current page has to be passed in: the stored snapshot
/// is the *whole list*, so a second page has to be concatenated, not stored alone.
private func loadSessions(
    client: SessionHistoryClientProtocol,
    cacheStore: SessionHistoryCacheStoreProtocol,
    scope: String,
    currentItems: [SessionHistoryItem],
    cursor: String?,
    appending: Bool
) async -> AppAction? {
    do {
        let page = try await client.listSessions(cursor: cursor, size: nil)
        guard !Task.isCancelled else { return nil }
        // A cache write that fails must not fail the load: the data is real and
        // about to be on screen, and the cache is only what makes the *next*
        // visit nicer. Disk-full would otherwise turn a working list into an
        // error page.
        try? await cacheStore.saveSnapshot(
            CachedSessionHistorySnapshot(
                items: appending ? currentItems + page.items : page.items,
                nextCursor: page.nextCursor
            ),
            scope: scope
        )
        return .sessionHistory(.loadSucceeded(page, appending: appending))
    } catch is CancellationError {
        return nil
    } catch {
        guard !Task.isCancelled else { return nil }
        return .sessionHistory(.loadFailed(error.localizedDescription))
    }
}
