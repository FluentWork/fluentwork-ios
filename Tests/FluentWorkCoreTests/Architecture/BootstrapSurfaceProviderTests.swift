import FactoryKit
import FluentWorkFeatureFlags
import Testing
import TGFeatureFlag
@testable import FluentWorkCore

/// Tests for the bootstrap surface provider mechanism.
@Suite("Bootstrap Surface Provider")
struct BootstrapSurfaceProviderTests {
    
    @Test("Default provider returns speaking room")
    func defaultProviderReturnsSpeakingRoom() async throws {
        let client = ResolverBackedBootstrapClient()
        let snapshot = try await client.loadBootstrap()
        
        #expect(snapshot.preferredSurface == .speakingRoom)
    }
    
    @Test("Custom provider closure is called at bootstrap time")
    func customProviderIsCalledAtBootstrapTime() async throws {
        var callCount = 0
        let client = ResolverBackedBootstrapClient(
            preferredSurfaceProvider: {
                callCount += 1
                return .dailyRead
            }
        )
        
        let snapshot = try await client.loadBootstrap()
        
        #expect(snapshot.preferredSurface == .dailyRead)
        #expect(callCount == 1)
    }
    
    @Test("Provider is evaluated on each bootstrap call")
    func providerIsEvaluatedOnEachCall() async throws {
        var surfaces: [WorkspaceSurface] = [.speakingRoom, .dailyRead, .corpus]
        var index = 0
        
        let client = ResolverBackedBootstrapClient(
            preferredSurfaceProvider: {
                defer { index += 1 }
                return surfaces[index % surfaces.count]
            }
        )
        
        let snapshot1 = try await client.loadBootstrap()
        #expect(snapshot1.preferredSurface == .speakingRoom)
        
        let snapshot2 = try await client.loadBootstrap()
        #expect(snapshot2.preferredSurface == .dailyRead)
        
        let snapshot3 = try await client.loadBootstrap()
        #expect(snapshot3.preferredSurface == .corpus)
    }
    
    @Test("Container factory allows override")
    func containerFactoryAllowsOverride() async throws {
        let container = Container()
        container.preferredSurfaceProvider.register {
            { .corpus }
        }
        
        let client = ResolverBackedBootstrapClient(
            resolver: container.featureFlagResolver(),
            preferredSurfaceProvider: container.preferredSurfaceProvider()
        )
        
        let snapshot = try await client.loadBootstrap()
        #expect(snapshot.preferredSurface == .corpus)
    }
    
    @Test("Bootstrap client factory integrates provider")
    func bootstrapClientFactoryIntegratesProvider() async throws {
        let container = Container()
        container.preferredSurfaceProvider.register {
            { .dailyRead }
        }
        
        let client = container.bootstrapClient()
        let snapshot = try await client.loadBootstrap()
        
        #expect(snapshot.preferredSurface == .dailyRead)
    }
}

#if DEBUG
/// Tests for debug-only configuration utilities.
@Suite("Debug Bootstrap Configuration")
@MainActor
struct DebugBootstrapConfigurationTests {
    
    @Test("Force surface overrides provider")
    func forceSurfaceOverridesProvider() async throws {
        let container = Container()
        container.preferredSurfaceProvider.register {
            { .corpus }
        }
        
        DebugBootstrapConfiguration.forceSurface(.dailyRead)
        
        let client = container.bootstrapClient()
        let snapshot = try await client.loadBootstrap()
        
        #expect(snapshot.preferredSurface == .dailyRead)
        
        // Cleanup
        DebugBootstrapConfiguration.reset()
    }
    
    @Test("Launch argument override respects arguments")
    func launchArgumentOverrideRespectsArguments() {
        // Save original arguments
        let originalArgs = CommandLine.arguments
        defer {
            // This is read-only, but the test demonstrates the logic path
        }
        
        let container = Container()
        DebugBootstrapConfiguration.configureLaunchArgumentOverride()
        
        let provider = container.preferredSurfaceProvider()
        
        // Default behavior when no args are present
        let defaultSurface = provider()
        #expect(defaultSurface == .speakingRoom)
        
        // Cleanup
        DebugBootstrapConfiguration.reset()
    }
    
    @Test("User defaults configuration reads stored value")
    func userDefaultsConfigurationReadsStoredValue() async throws {
        let testKey = "test.bootstrap.surface.\(UUID().uuidString)"
        UserDefaults.standard.set("dailyRead", forKey: testKey)
        defer {
            UserDefaults.standard.removeObject(forKey: testKey)
        }
        
        let container = Container()
        DebugBootstrapConfiguration.configureFromUserDefaults(key: testKey)
        
        let client = container.bootstrapClient()
        let snapshot = try await client.loadBootstrap()
        
        #expect(snapshot.preferredSurface == .dailyRead)
        
        // Cleanup
        DebugBootstrapConfiguration.reset()
    }
    
    @Test("User defaults configuration falls back to default")
    func userDefaultsConfigurationFallsBackToDefault() async throws {
        let testKey = "test.bootstrap.surface.missing.\(UUID().uuidString)"
        
        let container = Container()
        DebugBootstrapConfiguration.configureFromUserDefaults(key: testKey)
        
        let client = container.bootstrapClient()
        let snapshot = try await client.loadBootstrap()
        
        #expect(snapshot.preferredSurface == .speakingRoom)
        
        // Cleanup
        DebugBootstrapConfiguration.reset()
    }
    
    @Test("Reset restores default behavior")
    func resetRestoresDefaultBehavior() async throws {
        let container = Container()
        
        // Override
        DebugBootstrapConfiguration.forceSurface(.corpus)
        let snapshot1 = try await container.bootstrapClient().loadBootstrap()
        #expect(snapshot1.preferredSurface == .corpus)
        
        // Reset
        DebugBootstrapConfiguration.reset()
        let snapshot2 = try await container.bootstrapClient().loadBootstrap()
        #expect(snapshot2.preferredSurface == .speakingRoom)
    }
}
#endif
