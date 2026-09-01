import Foundation
import Moya
import FluentWorkNetworking

/// Network client that automatically injects auth tokens and handles 401 errors.
///
/// Responsibilities:
/// - Inject current access token into request headers
/// - Detect 401 Unauthorized responses
/// - Trigger token refresh via `TokenRefreshCoordinator`
/// - Retry the original request with the new token (once)
/// - Cache token checks to avoid redundant validation (actor-safe)
///
/// This is a decorator over `NetworkClientProtocol` — wraps any base client
/// (real `MoyaNetworkClient` or test stub) with auth + retry logic.
public actor AuthenticatedNetworkClient: NetworkClientProtocol {
    private let baseClient: NetworkClientProtocol
    private let tokenRefreshCoordinator: TokenRefreshCoordinator
    
    /// Cached token and check timestamp (avoid redundant checks within 1 second)
    private var cachedToken: (token: AuthToken, checkedAt: Date)?
    
    public init(
        baseClient: NetworkClientProtocol,
        tokenRefreshCoordinator: TokenRefreshCoordinator
    ) {
        self.baseClient = baseClient
        self.tokenRefreshCoordinator = tokenRefreshCoordinator
    }
    
    public func requestData(for target: any FluentWorkTargetType) async throws -> Data {
        // 1. Get valid token (with caching to avoid redundant checks)
        let token = try await getValidTokenWithCache()
        
        // 2. Inject token into target
        let authenticatedTarget = AuthenticatedTarget(base: target, token: token.value)
        
        // 3. Execute request
        do {
            return try await baseClient.requestData(for: authenticatedTarget)
        } catch let error as APIError {
            // 4. Handle 401: refresh token and retry once
            if case .backend(let code, _) = error, code == "http_401" {
                return try await retryWithRefreshedToken(target: target)
            }
            throw error
        }
    }
    
    /// Get valid token with local caching (avoid redundant coordinator calls)
    private func getValidTokenWithCache() async throws -> AuthToken {
        let now = Date()
        
        // Check if we have a recent cached token (within 1 second)
        if let cached = cachedToken,
           now.timeIntervalSince(cached.checkedAt) < 1.0 {
            return cached.token
        }
        
        // Fetch from coordinator (which has its own caching and deduplication)
        let token = try await tokenRefreshCoordinator.getValidToken()
        cachedToken = (token, now)
        return token
    }
    
    /// Retry logic after 401: force refresh, then retry once.
    private func retryWithRefreshedToken(target: any FluentWorkTargetType) async throws -> Data {
        // Clear local cache since token is invalid
        cachedToken = nil
        
        // Force token refresh
        let newToken = try await tokenRefreshCoordinator.handle401Error()
        
        // Update local cache
        cachedToken = (newToken, Date())
        
        // Retry with new token
        let authenticatedTarget = AuthenticatedTarget(base: target, token: newToken.value)
        return try await baseClient.requestData(for: authenticatedTarget)
    }
}

/// Wrapper target that injects Authorization header.
private struct AuthenticatedTarget: FluentWorkTargetType {
    let base: any FluentWorkTargetType
    let token: String
    
    var baseURL: URL { base.baseURL }
    var path: String { base.path }
    var method: Moya.Method { base.method }
    var task: Moya.Task { base.task }
    var sampleData: Data { base.sampleData }
    
    var headers: [String: String]? {
        var merged = base.headers ?? [:]
        merged["Authorization"] = "Bearer \(token)"
        return merged
    }
}
