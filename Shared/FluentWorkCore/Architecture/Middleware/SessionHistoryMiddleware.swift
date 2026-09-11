import FactoryKit
import FluentWorkNetworking
import Foundation
import TGReduxKit

/// Bridges `SessionHistoryAction` to `GET /api/v1/sessions`.
///
/// Deliberately thin, and thinner than `corpusMiddleware`: this list is
/// **read-only**. There is no cache, no outbox, no tombstone and no merge
/// rebuild, because there is nothing local to reconcile with the server —
/// sessions live in `practice_sessions`, and a client-side copy would be a
/// second source of truth for something the user never edits (`79_` §设计 1).
/// Copies of corpus live in that file because corpus *is* edited offline; this
/// one is not, so it does not get the machinery.
public func sessionHistoryMiddleware(container: Container? = nil) -> Middleware<AppState, AppAction> {
    let resolvedContainer = container ?? Container.shared
    let client = resolvedContainer.sessionHistoryClient()

    return { store, action, next in
        guard case .sessionHistory(let historyAction) = action else {
            return next(action)
        }

        switch historyAction {
        case .appear:
            // Read **before** `next(action)`. The reducer flips
            // `didRequestInitialLoad` while applying `.appear`, so after `next`
            // it is true whatever happened — and this guard, which asks "is
            // this the first one", would answer "no" every single time and the
            // list would never load at all. The reducer's guard is what keeps
            // the state honest; this one only keeps the network quiet when the
            // tab is switched away and back.
            let isFirstAppear = !store.state.sessionHistory.didRequestInitialLoad
            let base = next(action)
            guard isFirstAppear else { return base }
            return .merge(
                base,
                .task(id: AppTaskID.sessionHistoryLoad) {
                    await loadSessions(
                        client: client,
                        cursor: nil,
                        appending: false
                    )
                }
            )

        case .refreshRequested:
            let base = next(action)
            return .merge(
                base,
                .task(id: AppTaskID.sessionHistoryLoad) {
                    // Page one, replacing. `appending: false` is what makes a
                    // refresh drop rows that were paged in — correct here:
                    // those rows are the *older* ones, still on the server, and
                    // the user can page to them again.
                    await loadSessions(
                        client: client,
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
            let base = next(action)
            return .merge(
                base,
                .task(id: AppTaskID.sessionHistoryLoadMore) {
                    await loadSessions(
                        client: client,
                        cursor: cursor,
                        appending: true
                    )
                }
            )

        case .loadSucceeded, .loadFailed:
            return next(action)
        }
    }
}

/// One page, one action back.
///
/// Returns `AppAction?` rather than dispatching directly so the call sits in
/// the same `.task` shape as every other middleware here — and so cancellation
/// (task id reuse, a cancelled `.task`) drops the result instead of writing a
/// stale page over a newer one.
private func loadSessions(
    client: SessionHistoryClientProtocol,
    cursor: String?,
    appending: Bool
) async -> AppAction? {
    do {
        let page = try await client.listSessions(cursor: cursor, size: nil)
        guard !Task.isCancelled else { return nil }
        return .sessionHistory(.loadSucceeded(page, appending: appending))
    } catch is CancellationError {
        return nil
    } catch {
        guard !Task.isCancelled else { return nil }
        return .sessionHistory(.loadFailed(error.localizedDescription))
    }
}
