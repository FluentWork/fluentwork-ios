import Foundation
import FactoryKit
import FluentWorkDiagnostics
import FluentWorkFeatureFlags
import FluentWorkNetworking
import Testing
import TGReduxKit
@testable import FluentWorkCore

private struct MockBootstrapClient: BootstrapClientProtocol {
    let snapshot: BootstrapSnapshot
    let authInfo: AuthInfo?

    func loadBootstrap() async throws -> BootstrapResult {
        BootstrapResult(snapshot: snapshot, authInfo: authInfo)
    }
}

private struct FailingBootstrapClient: BootstrapClientProtocol {
    struct Failure: LocalizedError {
        var errorDescription: String? { "bootstrap failed for test" }
    }

    func loadBootstrap() async throws -> BootstrapResult {
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

/// The device id keys everything scoped per install, and the one thing that
/// needs it day to day is corpus seeding: `dev-up.sh` seeds a fixed
/// `corpus-seed-dev-device`, a physical device authenticates as its own guest,
/// and the corpus is scoped by user — so badge hits on a real phone silently
/// never fire until corpus is seeded against *that* id, with nothing anywhere
/// saying why (`docs/62` §0 item 4).
///
/// It was reachable only from the Keychain. This pins that a launch says it out
/// loud, because "where do I read the device id" is a question every device run
/// asks and the answer used to be "from the Keychain".
@MainActor
@Test func appLaunchLogsTheDeviceIdentity() async {
    let tracker = CapturingTracker()
    let container = makeIsolatedContainer(
        bootstrapClient: MockBootstrapClient(
            snapshot: BootstrapSnapshot(
                featureFlags: .firstWave,
                preferredSurface: .speakingRoom
            ),
            authInfo: AuthInfo(userID: "user-1", isGuest: true, deviceID: "DA87E7D4-TESTDEVICE")
        )
    )
    container.tracker.register { tracker }

    let store = AppStoreFactory.make(container: container)
    store.dispatch(.lifecycle(.appLaunched))
    await waitForBootstrap(store)

    let identity = tracker.events.first { $0.name == "device_identity" }
    #expect(identity?.properties["device_id"] == "DA87E7D4-TESTDEVICE")
    #expect(identity?.properties["user_id"] == "user-1")
    #expect(identity?.properties["is_guest"] == "true")
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
            ),
            authInfo: nil
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
    #expect(
        workspace.state.availableModules.map(\.moduleName)
            == ["SpeakingRoom", "Review", "DailyRead", "SessionHistory"]
    )
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

        func loadBootstrap() async throws -> BootstrapResult {
            await probe.markLoad()
            try await Task.sleep(nanoseconds: 150_000_000)
            return BootstrapResult(
                snapshot: BootstrapSnapshot(
                    featureFlags: .firstWave,
                    preferredSurface: .speakingRoom
                ),
                authInfo: nil
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

/// Two `.appLaunched` can hit `tryBegin` before reducer status is `.loading`.
/// Exactly one caller may start the load task.
@Test func bootstrapLoadGateConcurrentTryBeginSucceedsOnce() async {
    let gate = BootstrapLoadGate()
    let successes = BootstrapGateSuccessCounter()

    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<32 {
            group.addTask {
                if gate.tryBegin() {
                    await successes.increment()
                }
            }
        }
    }

    #expect(await successes.value == 1)
}

@Test func bootstrapLoadGateCanBeginAgainAfterEnd() {
    let gate = BootstrapLoadGate()
    #expect(gate.tryBegin())
    #expect(!gate.tryBegin())
    gate.end()
    #expect(gate.tryBegin())
}

private actor BootstrapGateSuccessCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
