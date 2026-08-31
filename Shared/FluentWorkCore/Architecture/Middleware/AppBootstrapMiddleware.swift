import FactoryKit
import FluentWorkNetworking
import Foundation
import TGReduxKit

public enum AppTaskID {
    public static let bootstrap: CancellationID = "app.bootstrap"
    public static let networkMonitor: CancellationID = "app.networkMonitor"
    public static let reviewPoll: CancellationID = "review.poll"

    public static func reviewAccept(cardID: String) -> CancellationID {
        CancellationID("review.accept.\(cardID)")
    }
}

public func makeAppMiddlewares(container: Container? = nil) -> [Middleware<AppState, AppAction>] {
    let resolvedContainer = container ?? Container.shared
    return [
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
