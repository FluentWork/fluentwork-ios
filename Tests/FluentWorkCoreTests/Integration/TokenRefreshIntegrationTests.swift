import Testing
import Foundation
import FactoryKit
import FluentWorkNetworking
@testable import FluentWorkCore

/// Integration tests verifying that TokenRefreshCoordinator and
/// AuthenticatedNetworkClient work together through AppDependencies
@Suite("Token Refresh Integration Tests")
struct TokenRefreshIntegrationTests {
    
    @Test("AppDependencies provides singleton TokenRefreshCoordinator")
    func appDependencies_providesSingletonCoordinator() async throws {
        // Given
        let container = Container.shared
        
        // When
        let coordinator1 = container.tokenRefreshCoordinator()
        let coordinator2 = container.tokenRefreshCoordinator()
        
        // Then: same instance (singleton)
        #expect(coordinator1 === coordinator2)
    }
    
    @Test("AppDependencies wires AuthenticatedNetworkClient")
    func appDependencies_wiresAuthenticatedClient() async throws {
        // Given
        let container = Container.shared
        
        // When: resolve network client from container
        let networkClient = container.networkClient()
        
        // Then: it's an AuthenticatedNetworkClient
        #expect(networkClient is AuthenticatedNetworkClient)
    }
    
    @Test("TokenRefreshCoordinator is singleton across multiple resolutions")
    func tokenRefreshCoordinator_isSingleton() async throws {
        // Given
        let container = Container.shared
        
        // When: resolve multiple times
        let instance1 = container.tokenRefreshCoordinator()
        let instance2 = container.tokenRefreshCoordinator()
        let instance3 = container.tokenRefreshCoordinator()
        
        // Then: all point to same instance
        #expect(instance1 === instance2)
        #expect(instance2 === instance3)
    }
}
