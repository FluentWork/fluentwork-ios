import FactoryKit
import FluentWorkNetworking
import Foundation
import TGReduxKit

public enum AppTaskID {
    public static let bootstrap: CancellationID = "app.bootstrap"
    public static let networkMonitor: CancellationID = "app.networkMonitor"
}

public func makeAppMiddlewares(container: Container? = nil) -> [Middleware<AppState, AppAction>] {
    let resolvedContainer = container ?? Container.shared
    return [
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
