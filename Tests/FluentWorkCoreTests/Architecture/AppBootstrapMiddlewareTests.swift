import Foundation
import FactoryKit
import FluentWorkFeatureFlags
import Testing
@testable import FluentWorkCore

private struct MockBootstrapClient: BootstrapClientProtocol {
    let snapshot: BootstrapSnapshot

    func loadBootstrap() async throws -> BootstrapSnapshot {
        snapshot
    }
}

private struct FailingBootstrapClient: BootstrapClientProtocol {
    struct Failure: LocalizedError {
        var errorDescription: String? { "bootstrap failed for test" }
    }

    func loadBootstrap() async throws -> BootstrapSnapshot {
        throw Failure()
    }
}

@MainActor
@Test func appLaunchMiddlewareUsesInjectedBootstrapClient() async {
    Container.shared.reset()
    defer { Container.shared.reset() }

    Container.shared.bootstrapClient.register {
        MockBootstrapClient(
            snapshot: BootstrapSnapshot(
                featureFlags: .firstWave,
                preferredSurface: .speakingRoom
            )
        )
    }

    let store = AppStoreFactory.make()
    let featureFlags = store.featureFlagsScope()
    let speakingRoom = store.speakingRoomScope()
    let workspace = store.workspaceScope()

    store.dispatch(.lifecycle(.appLaunched))
    try? await Task.sleep(nanoseconds: 50_000_000)

    #expect(store.state.bootstrapStatus == .ready)
    #expect(featureFlags.state.isRemoteLoaded)
    #expect(featureFlags.state.isEnabled(.speakingRoom))
    #expect(workspace.state.activeSurface == .speakingRoom)
    #expect(workspace.state.isBootstrapComplete)
    #expect(workspace.state.availableModules.map(\.moduleName) == ["SpeakingRoom", "Review"])
    #expect(speakingRoom.state.isBootstrapReady)
}

@MainActor
@Test func appLaunchMiddlewareSurfacesBootstrapFailure() async {
    Container.shared.reset()
    defer { Container.shared.reset() }

    Container.shared.bootstrapClient.register {
        FailingBootstrapClient()
    }

    let store = AppStoreFactory.make()
    store.dispatch(.lifecycle(.appLaunched))
    try? await Task.sleep(nanoseconds: 50_000_000)

    #expect(store.state.bootstrapStatus == .failed)
    #expect(store.state.lastErrorMessage == "bootstrap failed for test")
}
