import FactoryKit
import Foundation
import TGReduxKit

public enum AppTaskID {
    public static let bootstrap: CancellationID = "app.bootstrap"
}

public func makeAppMiddlewares(container: Container? = nil) -> [Middleware<AppState, AppAction>] {
    let resolvedContainer = container ?? Container.shared
    return [
        appBootstrapMiddleware(container: resolvedContainer),
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

private func appBootstrapErrorMessage(_ error: any Error) -> String {
    if let localized = error as? any LocalizedError,
       let description = localized.errorDescription,
       !description.isEmpty {
        return description
    }

    return "Bootstrap failed. Please try again."
}
