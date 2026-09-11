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
        case .appear, .refreshRequested:
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

        case .loadSucceeded, .loadFailed, .detailSucceeded, .detailFailed:
            return next(action)
        }
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
