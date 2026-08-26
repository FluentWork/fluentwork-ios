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
    /// Text-degrade wiring point; throws until backend B7 lands.
    func sendSessionMessage(sessionID: String, accessToken: String, text: String) async throws
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
        text: String
    ) async throws {
        // Endpoint not in OpenAPI yet (B7). Keep the call site wired and fail closed.
        _ = sessionID
        _ = accessToken
        _ = text
        throw APIError.backend(
            code: "messages_not_implemented",
            message: "POST /sessions/{id}/messages is not available until backend B7."
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
