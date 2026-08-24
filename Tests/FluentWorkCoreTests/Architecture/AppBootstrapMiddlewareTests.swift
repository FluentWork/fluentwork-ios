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

@MainActor
@Test func repeatedAppLaunchDoesNotRestartBootstrapWhileLoading() async {
    actor Probe {
        private(set) var loadCount = 0

        func markLoad() {
            loadCount += 1
        }
    }

    struct SlowBootstrapClient: BootstrapClientProtocol {
        let probe: Probe

        func loadBootstrap() async throws -> BootstrapSnapshot {
            await probe.markLoad()
            try await Task.sleep(nanoseconds: 100_000_000)
            return BootstrapSnapshot(
                featureFlags: .firstWave,
                preferredSurface: .speakingRoom
            )
        }
    }

    Container.shared.reset()
    defer { Container.shared.reset() }

    let probe = Probe()
    Container.shared.bootstrapClient.register {
        SlowBootstrapClient(probe: probe)
    }

    let store = AppStoreFactory.make()
    store.dispatch(.lifecycle(.appLaunched))
    store.dispatch(.lifecycle(.appLaunched))

    try? await Task.sleep(nanoseconds: 20_000_000)
    #expect(store.state.bootstrapStatus == .loading)
    #expect(await probe.loadCount == 1)
}
