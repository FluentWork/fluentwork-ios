import Foundation
import FactoryKit
import FluentWorkFeatureFlags
import FluentWorkNetworking
import Testing
import TGReduxKit
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
private func makeIsolatedContainer(
    bootstrapClient: any BootstrapClientProtocol
) -> Container {
    let container = Container()
    container.networkMonitor.register {
        StubNetworkMonitor(snapshot: .connected)
    }
    container.bootstrapClient.register { bootstrapClient }
    return container
}

@MainActor
private func waitForBootstrap(
    _ store: Store<AppState, AppAction>,
    timeoutNanoseconds: UInt64 = 2_000_000_000
) async {
    let step: UInt64 = 20_000_000
    var waited: UInt64 = 0
    while waited < timeoutNanoseconds {
        switch store.state.bootstrapStatus {
        case .ready, .failed:
            return
        case .idle, .loading:
            try? await Task.sleep(nanoseconds: step)
            waited += step
        }
    }
}

@MainActor
@Test func appLaunchMiddlewareUsesInjectedBootstrapClient() async {
    let container = makeIsolatedContainer(
        bootstrapClient: MockBootstrapClient(
            snapshot: BootstrapSnapshot(
                featureFlags: .firstWave,
                preferredSurface: .speakingRoom
            )
        )
    )

    let store = AppStoreFactory.make(container: container)
    let featureFlags = store.featureFlagsScope()
    let speakingRoom = store.speakingRoomScope()
    let workspace = store.workspaceScope()

    store.dispatch(.lifecycle(.appLaunched))
    await waitForBootstrap(store)

    #expect(store.state.bootstrapStatus == .ready)
    #expect(featureFlags.state.isRemoteLoaded)
    #expect(featureFlags.state.isEnabled(.speakingRoom))
    #expect(workspace.state.activeSurface == .speakingRoom)
    #expect(workspace.state.isBootstrapComplete)
    #expect(workspace.state.availableModules.map(\.moduleName) == ["SpeakingRoom", "Review"])
    #expect(speakingRoom.state.isBootstrapReady)
    #expect(store.state.network.isConnected)
}

@MainActor
@Test func appLaunchMiddlewareSurfacesBootstrapFailure() async {
    let container = makeIsolatedContainer(bootstrapClient: FailingBootstrapClient())
    let store = AppStoreFactory.make(container: container)

    store.dispatch(.lifecycle(.appLaunched))
    await waitForBootstrap(store)

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
            try await Task.sleep(nanoseconds: 150_000_000)
            return BootstrapSnapshot(
                featureFlags: .firstWave,
                preferredSurface: .speakingRoom
            )
        }
    }

    let probe = Probe()
    let container = makeIsolatedContainer(
        bootstrapClient: SlowBootstrapClient(probe: probe)
    )
    let store = AppStoreFactory.make(container: container)

    store.dispatch(.lifecycle(.appLaunched))
    store.dispatch(.lifecycle(.appLaunched))

    try? await Task.sleep(nanoseconds: 40_000_000)
    #expect(store.state.bootstrapStatus == .loading)
    #expect(await probe.loadCount == 1)
}
