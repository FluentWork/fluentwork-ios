import FactoryKit
import FluentWorkFeatureFlags
import Foundation
import Testing
@testable import FluentWorkCore

private struct SurfaceOnlyBootstrapClient: BootstrapClientProtocol {
    let preferredSurfaceProvider: @Sendable () -> WorkspaceSurface

    func loadBootstrap() async throws -> BootstrapResult {
        BootstrapResult(
            snapshot: BootstrapSnapshot(
                featureFlags: .firstWave,
                preferredSurface: preferredSurfaceProvider()
            )
        )
    }
}

private final class SurfaceProviderCallTracker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "BootstrapSurfaceProviderTests.call-tracker")
    private var wasCalled = false

    func markCalled() {
        queue.sync {
            wasCalled = true
        }
    }

    func value() -> Bool {
        queue.sync {
            wasCalled
        }
    }
}

/// Tests for the bootstrap surface provider mechanism.
@Suite("Bootstrap Surface Provider")
@MainActor
struct BootstrapSurfaceProviderTests {

    /// Create an isolated container for testing with custom configuration.
    private func makeTestContainer(
        preferredSurface: WorkspaceSurface = .speakingRoom
    ) -> Container {
        let container = Container()
        container.preferredSurfaceProvider.register {
            { preferredSurface }
        }
        container.bootstrapClient.register {
            SurfaceOnlyBootstrapClient(
                preferredSurfaceProvider: container.preferredSurfaceProvider()
            )
        }
        return container
    }

    @Test("Default provider returns speaking room")
    func defaultProviderReturnsSpeakingRoom() async throws {
        let container = makeTestContainer()
        let client = container.bootstrapClient()
        let result = try await client.loadBootstrap()

        #expect(result.snapshot.preferredSurface == .speakingRoom)
    }

    @Test("Container factory allows override")
    func containerFactoryAllowsOverride() async throws {
        let container = makeTestContainer(preferredSurface: .review)
        let client = container.bootstrapClient()
        let result = try await client.loadBootstrap()

        #expect(result.snapshot.preferredSurface == .review)
    }

    @Test("Custom provider closure is called at bootstrap time")
    func customProviderIsCalledAtBootstrapTime() async throws {
        let tracker = SurfaceProviderCallTracker()
        let container = Container()
        container.preferredSurfaceProvider.register {
            {
                tracker.markCalled()
                return .workbench
            }
        }
        container.bootstrapClient.register {
            SurfaceOnlyBootstrapClient(
                preferredSurfaceProvider: container.preferredSurfaceProvider()
            )
        }

        let client = container.bootstrapClient()
        let result = try await client.loadBootstrap()

        #expect(result.snapshot.preferredSurface == .workbench)
        #expect(tracker.value())
    }

    @Test("Provider is evaluated on each bootstrap call")
    func providerIsEvaluatedOnEachCall() async throws {
        let container = makeTestContainer(preferredSurface: .speakingRoom)
        let client = container.bootstrapClient()

        let result1 = try await client.loadBootstrap()
        #expect(result1.snapshot.preferredSurface == .speakingRoom)

        let result2 = try await client.loadBootstrap()
        #expect(result2.snapshot.preferredSurface == .speakingRoom)

        let result3 = try await client.loadBootstrap()
        #expect(result3.snapshot.preferredSurface == .speakingRoom)
    }

    @Test("Bootstrap client factory integrates provider")
    func bootstrapClientFactoryIntegratesProvider() async throws {
        let container = makeTestContainer(preferredSurface: .workbench)
        let client = container.bootstrapClient()
        let result = try await client.loadBootstrap()

        #expect(result.snapshot.preferredSurface == .workbench)
    }
}

#if DEBUG
/// Tests for debug-only configuration utilities.
@Suite("Debug Bootstrap Configuration")
@MainActor
struct DebugBootstrapConfigurationTests {

    init() {
        DebugBootstrapConfiguration.reset()
        Container.shared.preferredSurfaceProvider.reset()
        Container.shared.bootstrapClient.reset()
    }

    private func installSharedBootstrapClient() {
        Container.shared.bootstrapClient.register {
            SurfaceOnlyBootstrapClient(
                preferredSurfaceProvider: Container.shared.preferredSurfaceProvider()
            )
        }
    }

    @Test("Force surface overrides provider")
    func forceSurfaceOverridesProvider() async throws {
        DebugBootstrapConfiguration.forceSurface(.workbench)
        installSharedBootstrapClient()

        let client = Container.shared.bootstrapClient()
        let result = try await client.loadBootstrap()

        #expect(result.snapshot.preferredSurface == .workbench)

        DebugBootstrapConfiguration.reset()
        Container.shared.preferredSurfaceProvider.reset()
        Container.shared.bootstrapClient.reset()
    }

    @Test("User defaults configuration reads stored value")
    func userDefaultsConfigurationReadsStoredValue() async throws {
        let testKey = "test.bootstrap.surface.\(UUID().uuidString)"
        UserDefaults.standard.set("workbench", forKey: testKey)
        defer {
            UserDefaults.standard.removeObject(forKey: testKey)
        }

        DebugBootstrapConfiguration.configureFromUserDefaults(key: testKey)
        installSharedBootstrapClient()

        let client = Container.shared.bootstrapClient()
        let result = try await client.loadBootstrap()

        #expect(result.snapshot.preferredSurface == .workbench)

        DebugBootstrapConfiguration.reset()
        Container.shared.preferredSurfaceProvider.reset()
        Container.shared.bootstrapClient.reset()
    }

    @Test("User defaults configuration falls back to default")
    func userDefaultsConfigurationFallsBackToDefault() async throws {
        let testKey = "test.bootstrap.surface.missing.\(UUID().uuidString)"

        DebugBootstrapConfiguration.configureFromUserDefaults(key: testKey)
        installSharedBootstrapClient()

        let client = Container.shared.bootstrapClient()
        let result = try await client.loadBootstrap()

        #expect(result.snapshot.preferredSurface == .speakingRoom)

        DebugBootstrapConfiguration.reset()
        Container.shared.preferredSurfaceProvider.reset()
        Container.shared.bootstrapClient.reset()
    }

    @Test("Reset restores default behavior")
    func resetRestoresDefaultBehavior() async throws {
        DebugBootstrapConfiguration.forceSurface(.review)
        installSharedBootstrapClient()

        let client1 = Container.shared.bootstrapClient()
        let result1 = try await client1.loadBootstrap()
        #expect(result1.snapshot.preferredSurface == .review)

        DebugBootstrapConfiguration.reset()
        Container.shared.preferredSurfaceProvider.reset()
        Container.shared.bootstrapClient.reset()
        installSharedBootstrapClient()

        let client2 = Container.shared.bootstrapClient()
        let result2 = try await client2.loadBootstrap()
        #expect(result2.snapshot.preferredSurface == .speakingRoom)

        DebugBootstrapConfiguration.reset()
        Container.shared.preferredSurfaceProvider.reset()
        Container.shared.bootstrapClient.reset()
    }
}
#endif
