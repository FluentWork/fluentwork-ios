import Foundation
import Moya

/// Session / auth REST surface for first-wave speaking-room APIs.
public protocol SessionAPIClientProtocol: Sendable {
    func issueGuest(deviceID: String) async throws -> TokenResponse
    func mergeGuestAccount(deviceID: String, accessToken: String) async throws -> MergeResponse
    func createSession(
        accessToken: String,
        materialID: String?,
        sceneType: String?
    ) async throws -> CreateSessionResponse
    func getSessionReview(sessionID: String, accessToken: String) async throws -> ReviewPollResponse
    /// Degraded-text path: `POST /sessions/{id}/messages` with `channel: text` (B7).
    func sendSessionMessage(
        sessionID: String,
        accessToken: String,
        text: String,
        channel: String
    ) async throws -> PostMessageResponse
    /// Refresh access token using current token
    func refreshToken(_ accessToken: String) async throws -> AuthToken
}

public final class SessionAPIClient: SessionAPIClientProtocol, Sendable {
    private let network: NetworkClientProtocol
    private let baseURL: URL

    public init(
        network: NetworkClientProtocol,
        baseURL: URL
    ) {
        self.network = network
        self.baseURL = baseURL
    }

    public func issueGuest(deviceID: String) async throws -> TokenResponse {
        try await decode(TokenResponse.self, .issueGuest(deviceID: deviceID))
    }

    public func mergeGuestAccount(deviceID: String, accessToken: String) async throws -> MergeResponse {
        try await decode(
            MergeResponse.self,
            .mergeGuestAccount(deviceID: deviceID, accessToken: accessToken)
        )
    }

    public func createSession(
        accessToken: String,
        materialID: String? = nil,
        sceneType: String? = nil
    ) async throws -> CreateSessionResponse {
        try await decode(
            CreateSessionResponse.self,
            .createSession(
                accessToken: accessToken,
                materialID: materialID,
                sceneType: sceneType
            )
        )
    }

    public func getSessionReview(
        sessionID: String,
        accessToken: String
    ) async throws -> ReviewPollResponse {
        try await decode(
            ReviewPollResponse.self,
            .getSessionReview(sessionID: sessionID, accessToken: accessToken)
        )
    }

    public func sendSessionMessage(
        sessionID: String,
        accessToken: String,
        text: String,
        channel: String = "text"
    ) async throws -> PostMessageResponse {
        try await decode(
            PostMessageResponse.self,
            .sendSessionMessage(
                sessionID: sessionID,
                accessToken: accessToken,
                text: text,
                channel: channel
            )
        )
    }
    
    public func refreshToken(_ accessToken: String) async throws -> AuthToken {
        let tokenResponse = try await decode(
            TokenResponse.self,
            .refreshToken(accessToken: accessToken)
        )
        let expiresAt = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        return AuthToken(
            value: tokenResponse.accessToken,
            expiresAt: expiresAt
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, _ api: FluentWorkAPI) async throws -> T {
        let data = try await network.requestData(
            for: AbsoluteFluentWorkTarget(baseURL: baseURL, api: api)
        )
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(description: error.localizedDescription)
        }
    }
}
