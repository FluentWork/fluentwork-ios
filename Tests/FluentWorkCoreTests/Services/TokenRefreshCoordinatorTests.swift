import Testing
import Foundation
@testable import FluentWorkCore
@testable import FluentWorkNetworking

@Suite("TokenRefreshCoordinator Tests")
struct TokenRefreshCoordinatorTests {
    
    // MARK: - Mock Dependencies
    
    final class MockTokenStore: AuthTokenStoreProtocol, @unchecked Sendable {
        var savedAccessToken: AuthToken?
        var loadAccessTokenCallCount = 0
        var saveAccessTokenCallCount = 0
        var clearAllTokensCallCount = 0
        private var _deviceID = "test-device"
        private var _userID: String?
        private var _isGuest = false
        
        func loadAccessToken() throws -> AuthToken? {
            loadAccessTokenCallCount += 1
            return savedAccessToken
        }
        
        func saveAccessToken(_ token: AuthToken) throws {
            saveAccessTokenCallCount += 1
            savedAccessToken = token
        }
        
        // Required by AuthTokenStoreProtocol
        func deviceID() throws -> String {
            _deviceID
        }
        
        func accessToken() throws -> String? {
            savedAccessToken?.value
        }
        
        func save(tokens: TokenResponse, deviceID: String) throws {
            savedAccessToken = AuthToken(
                value: tokens.accessToken,
                expiresAt: Date().addingTimeInterval(3600)
            )
            _deviceID = deviceID
            _userID = tokens.userID
            _isGuest = tokens.isGuest
        }
        
        func clear() throws {
            clearAllTokensCallCount += 1
            savedAccessToken = nil
            _userID = nil
            _isGuest = false
        }
        
        func userID() throws -> String? {
            _userID
        }
        
        func isGuest() throws -> Bool {
            _isGuest
        }
    }
    
    final class MockSessionAPI: SessionAPIClientProtocol, @unchecked Sendable {
        var refreshTokenStub: AuthToken?
        var refreshTokenError: Error?
        var refreshTokenCallCount = 0
        var lastRefreshTokenInput: String?
        
        func refreshToken(_ accessToken: String) async throws -> AuthToken {
            refreshTokenCallCount += 1
            lastRefreshTokenInput = accessToken
            
            if let error = refreshTokenError {
                throw error
            }
            guard let stub = refreshTokenStub else {
                fatalError("refreshTokenStub not configured")
            }
            return stub
        }
        
        func issueGuest(deviceID: String) async throws -> TokenResponse {
            fatalError("Not implemented")
        }
        
        func mergeGuestAccount(deviceID: String, accessToken: String) async throws -> MergeResponse {
            fatalError("Not implemented")
        }
        
        func createSession(accessToken: String, materialID: String?, sceneType: String?) async throws -> CreateSessionResponse {
            fatalError("Not implemented")
        }
        
        func getSessionReview(sessionID: String, accessToken: String) async throws -> ReviewPollResponse {
            fatalError("Not implemented")
        }
        
        func sendSessionMessage(sessionID: String, accessToken: String, text: String, channel: String) async throws -> PostMessageResponse {
            fatalError("Not implemented")
        }
    }
    
    // MARK: - Test: Valid Token
    
    @Test("getValidToken with valid token returns immediately")
    func getValidToken_validToken_returnsImmediately() async throws {
        // Given: Token 还有 10 分钟过期
        let tokenStore = MockTokenStore()
        let sessionAPI = MockSessionAPI()
        let fixedTime = Date()
        let futureExpiry = fixedTime.addingTimeInterval(10 * 60)
        
        tokenStore.savedAccessToken = AuthToken(
            value: "valid-token",
            expiresAt: futureExpiry
        )
        
        let coordinator = TokenRefreshCoordinator(
            tokenStore: tokenStore,
            sessionAPI: sessionAPI,
            expiryBuffer: 5 * 60,
            currentTime: { fixedTime }
        )
        
        // When: 获取 token
        let result = try await coordinator.getValidToken()
        
        // Then: 直接返回，不刷新
        #expect(result.value == "valid-token")
        #expect(sessionAPI.refreshTokenCallCount == 0)
        #expect(tokenStore.loadAccessTokenCallCount == 1)
    }
    
    // MARK: - Test: Expiring Soon
    
    @Test("getValidToken with expiring token refreshes automatically")
    func getValidToken_expiringSoon_refreshesToken() async throws {
        // Given: Token 还有 3 分钟过期（小于 5 分钟缓冲）
        let tokenStore = MockTokenStore()
        let sessionAPI = MockSessionAPI()
        let fixedTime = Date()
        let soonExpiry = fixedTime.addingTimeInterval(3 * 60)
        
        tokenStore.savedAccessToken = AuthToken(
            value: "old-token",
            expiresAt: soonExpiry
        )
        
        sessionAPI.refreshTokenStub = AuthToken(
            value: "new-token",
            expiresAt: fixedTime.addingTimeInterval(60 * 60)
        )
        
        let coordinator = TokenRefreshCoordinator(
            tokenStore: tokenStore,
            sessionAPI: sessionAPI,
            expiryBuffer: 5 * 60,
            currentTime: { fixedTime }
        )
        
        // When: 获取 token
        let result = try await coordinator.getValidToken()
        
        // Then: 刷新并返回新 token
        #expect(result.value == "new-token")
        #expect(sessionAPI.refreshTokenCallCount == 1)
        #expect(sessionAPI.lastRefreshTokenInput == "old-token")
        #expect(tokenStore.saveAccessTokenCallCount == 1)
    }
    
    // MARK: - Test: No Token
    
    @Test("getValidToken without token throws noToken error")
    func getValidToken_noToken_throwsError() async throws {
        // Given: 没有 token
        let tokenStore = MockTokenStore()
        let sessionAPI = MockSessionAPI()
        
        let coordinator = TokenRefreshCoordinator(
            tokenStore: tokenStore,
            sessionAPI: sessionAPI
        )
        
        // When/Then: 抛出 noToken 错误
        await #expect(throws: TokenError.noToken) {
            try await coordinator.getValidToken()
        }
    }
    
    // MARK: - Test: Concurrent Requests
    
    @Test("getValidToken with concurrent requests only refreshes once")
    func getValidToken_concurrentRequests_onlyRefreshOnce() async throws {
        // Given: Token 即将过期
        let tokenStore = MockTokenStore()
        let sessionAPI = MockSessionAPI()
        let fixedTime = Date()
        let soonExpiry = fixedTime.addingTimeInterval(3 * 60)
        
        tokenStore.savedAccessToken = AuthToken(
            value: "old-token",
            expiresAt: soonExpiry
        )
        
        // 模拟慢速刷新（100ms）
        sessionAPI.refreshTokenStub = AuthToken(
            value: "new-token",
            expiresAt: fixedTime.addingTimeInterval(60 * 60)
        )
        
        let coordinator = TokenRefreshCoordinator(
            tokenStore: tokenStore,
            sessionAPI: sessionAPI,
            expiryBuffer: 5 * 60,
            currentTime: { fixedTime }
        )
        
        // When: 10 个并发请求
        let results = await withTaskGroup(of: AuthToken?.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try? await coordinator.getValidToken()
                }
            }
            
            var collected: [AuthToken?] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }
        
        // Then: 只刷新一次，所有请求都拿到新 token
        #expect(sessionAPI.refreshTokenCallCount == 1)
        #expect(results.count == 10)
        #expect(results.allSatisfy { $0?.value == "new-token" })
    }
    
    // MARK: - Test: 401 Error Handling
    
    @Test("handle401Error forces token refresh")
    func handle401Error_forcesRefresh() async throws {
        // Given: Token 还有效但收到 401
        let tokenStore = MockTokenStore()
        let sessionAPI = MockSessionAPI()
        let fixedTime = Date()
        let futureExpiry = fixedTime.addingTimeInterval(10 * 60)
        
        tokenStore.savedAccessToken = AuthToken(
            value: "invalid-token",
            expiresAt: futureExpiry
        )
        
        sessionAPI.refreshTokenStub = AuthToken(
            value: "new-token",
            expiresAt: fixedTime.addingTimeInterval(60 * 60)
        )
        
        let coordinator = TokenRefreshCoordinator(
            tokenStore: tokenStore,
            sessionAPI: sessionAPI,
            currentTime: { fixedTime }
        )
        
        // When: 处理 401
        let result = try await coordinator.handle401Error()
        
        // Then: 强制刷新
        #expect(result.value == "new-token")
        #expect(sessionAPI.refreshTokenCallCount == 1)
    }
    
    // MARK: - Test: Refresh Failure
    
    @Test("getValidToken refresh failure clears tokens")
    func getValidToken_refreshFails_clearsTokens() async throws {
        // Given: Token 即将过期，刷新会失败
        let tokenStore = MockTokenStore()
        let sessionAPI = MockSessionAPI()
        let fixedTime = Date()
        let soonExpiry = fixedTime.addingTimeInterval(3 * 60)
        
        tokenStore.savedAccessToken = AuthToken(
            value: "old-token",
            expiresAt: soonExpiry
        )
        
        struct RefreshError: Error {}
        sessionAPI.refreshTokenError = RefreshError()
        
        let coordinator = TokenRefreshCoordinator(
            tokenStore: tokenStore,
            sessionAPI: sessionAPI,
            expiryBuffer: 5 * 60,
            currentTime: { fixedTime }
        )
        
        // When: 尝试获取 token
        await #expect(throws: TokenError.refreshFailed(underlying: nil)) {
            try await coordinator.getValidToken()
        }
        
        // Then: 清理了所有 token
        #expect(tokenStore.clearAllTokensCallCount == 1)
        #expect(tokenStore.savedAccessToken == nil)
    }
    
    // MARK: - Test: Edge Cases
    
    @Test("getValidToken at exact expiry buffer boundary refreshes")
    func getValidToken_atExactBoundary_refreshes() async throws {
        // Given: Token 正好还有 5 分钟过期（等于缓冲时间）
        let tokenStore = MockTokenStore()
        let sessionAPI = MockSessionAPI()
        let fixedTime = Date()
        let boundaryExpiry = fixedTime.addingTimeInterval(5 * 60)
        
        tokenStore.savedAccessToken = AuthToken(
            value: "old-token",
            expiresAt: boundaryExpiry
        )
        
        sessionAPI.refreshTokenStub = AuthToken(
            value: "new-token",
            expiresAt: fixedTime.addingTimeInterval(60 * 60)
        )
        
        let coordinator = TokenRefreshCoordinator(
            tokenStore: tokenStore,
            sessionAPI: sessionAPI,
            expiryBuffer: 5 * 60,
            currentTime: { fixedTime }
        )
        
        // When: 获取 token
        let result = try await coordinator.getValidToken()
        
        // Then: 刷新（边界情况：timeUntilExpiry == buffer，不满足 > 条件）
        #expect(result.value == "new-token")
        #expect(sessionAPI.refreshTokenCallCount == 1)
    }
    
    @Test("getValidToken with already expired token refreshes")
    func getValidToken_alreadyExpired_refreshes() async throws {
        // Given: Token 已经过期
        let tokenStore = MockTokenStore()
        let sessionAPI = MockSessionAPI()
        let fixedTime = Date()
        let pastExpiry = fixedTime.addingTimeInterval(-10 * 60)
        
        tokenStore.savedAccessToken = AuthToken(
            value: "expired-token",
            expiresAt: pastExpiry
        )
        
        sessionAPI.refreshTokenStub = AuthToken(
            value: "new-token",
            expiresAt: fixedTime.addingTimeInterval(60 * 60)
        )
        
        let coordinator = TokenRefreshCoordinator(
            tokenStore: tokenStore,
            sessionAPI: sessionAPI,
            currentTime: { fixedTime }
        )
        
        // When: 获取 token
        let result = try await coordinator.getValidToken()
        
        // Then: 刷新并返回新 token
        #expect(result.value == "new-token")
        #expect(sessionAPI.refreshTokenCallCount == 1)
    }
}
