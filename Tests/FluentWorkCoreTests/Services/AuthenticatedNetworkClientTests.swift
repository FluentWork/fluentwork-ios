import Foundation
import Testing
import Moya
@testable import FluentWorkCore
@testable import FluentWorkNetworking

@Suite("AuthenticatedNetworkClient Tests")
struct AuthenticatedNetworkClientTests {
    
    // MARK: - Test Doubles
    
    final class MockBaseClient: NetworkClientProtocol, @unchecked Sendable {
        var requestCallCount = 0
        var capturedTargets: [String] = []
        var capturedHeaders: [[String: String]?] = []
        var responseHandler: (@Sendable (any FluentWorkTargetType) async throws -> Data)?
        var internalCallCount = 0  // For handler internal use
        
        func requestData(for target: any FluentWorkTargetType) async throws -> Data {
            requestCallCount += 1
            internalCallCount += 1
            capturedTargets.append(target.path)
            capturedHeaders.append(target.headers)
            
            if let handler = responseHandler {
                return try await handler(target)
            }
            
            return Data()
        }
    }
    
    final class MockTokenStore: AuthTokenStoreProtocol, @unchecked Sendable {
        private var _deviceID = "test-device"
        private var _userID: String?
        private var _isGuest = false
        var savedAccessToken: AuthToken?
        
        func loadAccessToken() throws -> AuthToken? {
            savedAccessToken
        }
        
        func saveAccessToken(_ token: AuthToken) throws {
            savedAccessToken = token
        }
        
        func deviceID() throws -> String { _deviceID }
        
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
            savedAccessToken = nil
            _userID = nil
            _isGuest = false
        }
        
        func userID() throws -> String? { _userID }
        func isGuest() throws -> Bool { _isGuest }
    }
    
    final class MockSessionAPI: SessionAPIClientProtocol, @unchecked Sendable {
        var refreshTokenStub: AuthToken?
        var refreshTokenCallCount = 0
        
        func refreshToken(_ accessToken: String) async throws -> AuthToken {
            refreshTokenCallCount += 1
            guard let stub = refreshTokenStub else {
                throw APIError.backend(code: "no_stub", message: "No refresh stub")
            }
            return stub
        }
        
        func issueGuest(deviceID: String) async throws -> TokenResponse {
            TokenResponse(
                userID: "guest-123",
                isGuest: true,
                status: "active",
                accessToken: "guest-token",
                refreshToken: "guest-refresh",
                expiresIn: 3600
            )
        }
        
        func mergeGuestAccount(deviceID: String, accessToken: String) async throws -> MergeResponse {
            MergeResponse(
                userID: "merged-user",
                isGuest: false,
                alreadyMerged: false
            )
        }
        
        func createSession(
            accessToken: String,
            materialID: String?,
            sceneType: String?
        ) async throws -> CreateSessionResponse {
            CreateSessionResponse(
                sessionID: "test-session",
                wssURL: "wss://test.com",
                ticket: "test-ticket",
                ticketExpiresIn: 300,
                ticketExpiresAt: "2026-09-01T23:00:00Z",
                sceneType: sceneType ?? "speaking_room",
                status: "active"
            )
        }
        
        func getSessionReview(sessionID: String, accessToken: String) async throws -> ReviewPollResponse {
            ReviewPollResponse(sessionID: sessionID, status: .pending, review: nil)
        }
        
        func sendSessionMessage(
            sessionID: String,
            accessToken: String,
            text: String,
            channel: String
        ) async throws -> PostMessageResponse {
            PostMessageResponse(
                sessionID: sessionID,
                reply: "",
                channel: channel,
                generator: "test"
            )
        }
    }
    
    // MARK: - Tests
    
    @Test("request injects Authorization header with valid token")
    func request_injectsAuthorizationHeader() async throws {
        // Given
        let baseClient = MockBaseClient()
        let tokenStore = MockTokenStore()
        let sessionAPI = MockSessionAPI()
        let fixedTime = Date()
        
        tokenStore.savedAccessToken = AuthToken(
            value: "test-token",
            expiresAt: fixedTime.addingTimeInterval(60 * 60)
        )
        
        let coordinator = TokenRefreshCoordinator(
            tokenStore: tokenStore,
            sessionAPI: sessionAPI,
            expiryBuffer: 5 * 60,
            currentTime: { fixedTime }
        )
        
        let client = AuthenticatedNetworkClient(
            baseClient: baseClient,
            tokenRefreshCoordinator: coordinator
        )
        
        let target = TestTarget(path: "/test", method: .get)
        
        // When
        _ = try await client.requestData(for: target)
        
        // Then
        #expect(baseClient.requestCallCount == 1)
        let headers = try #require(baseClient.capturedHeaders.first)
        #expect(headers?["Authorization"] == "Bearer test-token")
    }
    
    @Test("request with expiring token refreshes before sending")
    func request_withExpiringToken_refreshesFirst() async throws {
        // Given
        let baseClient = MockBaseClient()
        let tokenStore = MockTokenStore()
        let sessionAPI = MockSessionAPI()
        let fixedTime = Date()
        
        // Token expires in 3 minutes (< 5 minute buffer)
        tokenStore.savedAccessToken = AuthToken(
            value: "old-token",
            expiresAt: fixedTime.addingTimeInterval(3 * 60)
        )
        
        sessionAPI.refreshTokenStub = AuthToken(
            value: "refreshed-token",
            expiresAt: fixedTime.addingTimeInterval(60 * 60)
        )
        
        let coordinator = TokenRefreshCoordinator(
            tokenStore: tokenStore,
            sessionAPI: sessionAPI,
            expiryBuffer: 5 * 60,
            currentTime: { fixedTime }
        )
        
        let client = AuthenticatedNetworkClient(
            baseClient: baseClient,
            tokenRefreshCoordinator: coordinator
        )
        
        let target = TestTarget(path: "/test", method: .get)
        
        // When
        _ = try await client.requestData(for: target)
        
        // Then: refresh happened before request
        #expect(sessionAPI.refreshTokenCallCount == 1)
        let headers = try #require(baseClient.capturedHeaders.first)
        #expect(headers?["Authorization"] == "Bearer refreshed-token")
    }
    
    @Test("request with 401 error refreshes token and retries once")
    func request_with401_refreshesAndRetries() async throws {
        // Given
        let baseClient = MockBaseClient()
        let tokenStore = MockTokenStore()
        let sessionAPI = MockSessionAPI()
        let fixedTime = Date()
        
        tokenStore.savedAccessToken = AuthToken(
            value: "expired-token",
            expiresAt: fixedTime.addingTimeInterval(60 * 60)
        )
        
        sessionAPI.refreshTokenStub = AuthToken(
            value: "new-token",
            expiresAt: fixedTime.addingTimeInterval(60 * 60)
        )
        
        // First call returns 401, second succeeds
        baseClient.responseHandler = { [baseClient] target in
            if baseClient.internalCallCount == 1 {
                throw APIError.backend(code: "http_401", message: "Unauthorized")
            }
            return Data()
        }
        
        let coordinator = TokenRefreshCoordinator(
            tokenStore: tokenStore,
            sessionAPI: sessionAPI,
            expiryBuffer: 5 * 60,
            currentTime: { fixedTime }
        )
        
        let client = AuthenticatedNetworkClient(
            baseClient: baseClient,
            tokenRefreshCoordinator: coordinator
        )
        
        let target = TestTarget(path: "/test", method: .get)
        
        // When
        _ = try await client.requestData(for: target)
        
        // Then: two attempts (first 401, then retry with new token)
        #expect(baseClient.requestCallCount == 2)
        #expect(sessionAPI.refreshTokenCallCount == 1)
        
        let secondHeaders = try #require(baseClient.capturedHeaders.last)
        #expect(secondHeaders?["Authorization"] == "Bearer new-token")
    }
    
    @Test("request with non-401 error throws immediately without retry")
    func request_withNon401Error_throwsImmediately() async throws {
        // Given
        let baseClient = MockBaseClient()
        let tokenStore = MockTokenStore()
        let sessionAPI = MockSessionAPI()
        let fixedTime = Date()
        
        tokenStore.savedAccessToken = AuthToken(
            value: "valid-token",
            expiresAt: fixedTime.addingTimeInterval(60 * 60)
        )
        
        baseClient.responseHandler = { _ in
            throw APIError.backend(code: "http_500", message: "Server Error")
        }
        
        let coordinator = TokenRefreshCoordinator(
            tokenStore: tokenStore,
            sessionAPI: sessionAPI,
            expiryBuffer: 5 * 60,
            currentTime: { fixedTime }
        )
        
        let client = AuthenticatedNetworkClient(
            baseClient: baseClient,
            tokenRefreshCoordinator: coordinator
        )
        
        let target = TestTarget(path: "/test", method: .get)
        
        // When/Then
        await #expect(throws: APIError.self) {
            try await client.requestData(for: target)
        }
        
        #expect(baseClient.requestCallCount == 1)  // No retry
        #expect(sessionAPI.refreshTokenCallCount == 0)  // No refresh
    }
    
    @Test("request without token throws noToken error")
    func request_withoutToken_throwsNoTokenError() async throws {
        // Given
        let baseClient = MockBaseClient()
        let tokenStore = MockTokenStore()  // No token saved
        let sessionAPI = MockSessionAPI()
        
        let coordinator = TokenRefreshCoordinator(
            tokenStore: tokenStore,
            sessionAPI: sessionAPI
        )
        
        let client = AuthenticatedNetworkClient(
            baseClient: baseClient,
            tokenRefreshCoordinator: coordinator
        )
        
        let target = TestTarget(path: "/test", method: .get)
        
        // When/Then
        await #expect(throws: TokenError.self) {
            try await client.requestData(for: target)
        }
        
        #expect(baseClient.requestCallCount == 0)  // Never reached base client
    }
}

// MARK: - Test Target

private struct TestTarget: FluentWorkTargetType {
    let path: String
    let method: Moya.Method
    var baseURL: URL { URL(string: "https://api.test.com")! }
    var task: Moya.Task { .requestPlain }
    var headers: [String: String]? { nil }
    var sampleData: Data { Data() }
}
