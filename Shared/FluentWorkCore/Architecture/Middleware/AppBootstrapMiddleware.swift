import FactoryKit
import Foundation
import FluentWorkPluginSupport
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
        next(action)

        guard case .lifecycle(.appLaunched) = action else { return }
        let bootstrapClient = resolvedContainer.bootstrapClient()
        let pluginRegistry = resolvedContainer.featurePluginRegistry()

        store.runTask(id: AppTaskID.bootstrap) {
            await store.dispatch(.lifecycle(.bootstrapStarted))

            do {
                let snapshot = try await bootstrapClient.loadBootstrap()
                await store.dispatch(.lifecycle(.bootstrapSucceeded(snapshot)))
                await store.dispatch(
                    .workspace(.setAvailableModules(
                        pluginRegistry.enabledPlugins(for: snapshot.featureFlags)
                    ))
                )
            } catch {
                await store.dispatch(.lifecycle(.bootstrapFailed(appBootstrapErrorMessage(error))))
            }
        }
    }
}

private func appBootstrapErrorMessage(_ error: any Error) -> String {
    if let localized = error as? any LocalizedError,
       let description = localized.errorDescription,
       !description.isEmpty {
        return description
    }

    return String(describing: error)
}
