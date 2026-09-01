import FactoryKit
import FluentWorkFeatureFlags
import Foundation
import Testing
@testable import FluentWorkCore

/// Tests for the bootstrap surface provider mechanism.
@Suite("Bootstrap Surface Provider")
@MainActor
struct BootstrapSurfaceProviderTests {
    
    /// Create an isolated container for testing with custom configuration
    private func makeTestContainer(
        preferredSurface: WorkspaceSurface = .speakingRoom
    ) -> Container {
        let container = Container()
        container.preferredSurfaceProvider.register {
            { preferredSurface }
        }
        container.bootstrapClient.register {
            ResolverBackedBootstrapClient(
                resolver: FeatureFlagResolverFactory.makeFirstWaveResolver(),
                preferredSurfaceProvider: container.preferredSurfaceProvider()
            )
        }
        return container
    }
    
    @Test("Default provider returns speaking room")
    func defaultProviderReturnsSpeakingRoom() async throws {
        let container = makeTestContainer()
        let client = container.bootstrapClient()
        let snapshot = try await client.loadBootstrap()
        
        #expect(snapshot.preferredSurface == .speakingRoom)
    }
    
    @Test("Container factory allows override")
    func containerFactoryAllowsOverride() async throws {
        let container = makeTestContainer(preferredSurface: .review)
        let client = container.bootstrapClient()
        let snapshot = try await client.loadBootstrap()
        
        #expect(snapshot.preferredSurface == .review)
    }
    
    @Test("Custom provider closure is called at bootstrap time")
    func customProviderIsCalledAtBootstrapTime() async throws {
        // Use an atomic counter to verify the closure was called
        final class CallTracker: @unchecked Sendable {
            private let lock = NSLock()
            private var _wasCalled = false
            
            var wasCalled: Bool {
                lock.lock()
                defer { lock.unlock() }
                return _wasCalled
            }
            
            func markCalled() {
                lock.lock()
                defer { lock.unlock() }
                _wasCalled = true
            }
        }
        
        let tracker = CallTracker()
        let container = Container()
        container.preferredSurfaceProvider.register {
            {
                tracker.markCalled()
                return .workbench
            }
        }
        container.bootstrapClient.register {
            ResolverBackedBootstrapClient(
                resolver: FeatureFlagResolverFactory.makeFirstWaveResolver(),
                preferredSurfaceProvider: container.preferredSurfaceProvider()
            )
        }
        
        let client = container.bootstrapClient()
        let snapshot = try await client.loadBootstrap()
        
        #expect(snapshot.preferredSurface == .workbench)
        #expect(tracker.wasCalled == true)
    }
    
    @Test("Provider is evaluated on each bootstrap call")
    func providerIsEvaluatedOnEachCall() async throws {
        let container = makeTestContainer(preferredSurface: .speakingRoom)
        let client = container.bootstrapClient()
        
        // Verify that multiple calls work correctly
        let snapshot1 = try await client.loadBootstrap()
        #expect(snapshot1.preferredSurface == .speakingRoom)
        
        let snapshot2 = try await client.loadBootstrap()
        #expect(snapshot2.preferredSurface == .speakingRoom)
        
        let snapshot3 = try await client.loadBootstrap()
        #expect(snapshot3.preferredSurface == .speakingRoom)
    }
    
    @Test("Bootstrap client factory integrates provider")
    func bootstrapClientFactoryIntegratesProvider() async throws {
        let container = makeTestContainer(preferredSurface: .workbench)
        let client = container.bootstrapClient()
        let snapshot = try await client.loadBootstrap()
        
        #expect(snapshot.preferredSurface == .workbench)
    }
}

#if DEBUG
/// Tests for debug-only configuration utilities.
@Suite("Debug Bootstrap Configuration")
@MainActor
struct DebugBootstrapConfigurationTests {
    
    init() {
        // Reset state before each test
        DebugBootstrapConfiguration.reset()
        Container.shared.preferredSurfaceProvider.reset()
        Container.shared.bootstrapClient.reset()
    }
    
    @Test("Force surface overrides provider")
    func forceSurfaceOverridesProvider() async throws {
        // Use the shared container since DebugBootstrapConfiguration works with Container.shared
        DebugBootstrapConfiguration.forceSurface(.workbench)
        
        let client = Container.shared.bootstrapClient()
        let snapshot = try await client.loadBootstrap()
        
        #expect(snapshot.preferredSurface == .workbench)
        
        // Cleanup
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
        
        let client = Container.shared.bootstrapClient()
        let snapshot = try await client.loadBootstrap()
        
        #expect(snapshot.preferredSurface == .workbench)
        
        // Cleanup
        DebugBootstrapConfiguration.reset()
        Container.shared.preferredSurfaceProvider.reset()
        Container.shared.bootstrapClient.reset()
    }
    
    @Test("User defaults configuration falls back to default")
    func userDefaultsConfigurationFallsBackToDefault() async throws {
        let testKey = "test.bootstrap.surface.missing.\(UUID().uuidString)"
        
        DebugBootstrapConfiguration.configureFromUserDefaults(key: testKey)
        
        let client = Container.shared.bootstrapClient()
        let snapshot = try await client.loadBootstrap()
        
        #expect(snapshot.preferredSurface == .speakingRoom)
        
        // Cleanup
        DebugBootstrapConfiguration.reset()
        Container.shared.preferredSurfaceProvider.reset()
        Container.shared.bootstrapClient.reset()
    }
    
    @Test("Reset restores default behavior")
    func resetRestoresDefaultBehavior() async throws {
        // Override
        DebugBootstrapConfiguration.forceSurface(.review)
        let client1 = Container.shared.bootstrapClient()
        let snapshot1 = try await client1.loadBootstrap()
        #expect(snapshot1.preferredSurface == .review)
        
        // Reset
        DebugBootstrapConfiguration.reset()
        Container.shared.preferredSurfaceProvider.reset()
        Container.shared.bootstrapClient.reset()
        
        let client2 = Container.shared.bootstrapClient()
        let snapshot2 = try await client2.loadBootstrap()
        #expect(snapshot2.preferredSurface == .speakingRoom)
        
        // Cleanup
        DebugBootstrapConfiguration.reset()
        Container.shared.preferredSurfaceProvider.reset()
        Container.shared.bootstrapClient.reset()
    }
}
#endif
