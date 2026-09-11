import FluentWorkNetworking
import Foundation

/// The conversation list, behind auth.
public protocol SessionHistoryClientProtocol: Sendable {
    func listSessions(cursor: String?, size: Int?) async throws -> SessionHistoryPage
    func sessionDetail(sessionID: String) async throws -> SessionDetail
}

public final class DefaultSessionHistoryClient: SessionHistoryClientProtocol, Sendable {
    private let api: SessionHistoryAPIClientProtocol
    private let sessionAPI: SessionAPIClientProtocol
    private let tokens: AuthTokenStoreProtocol

    public init(
        api: SessionHistoryAPIClientProtocol,
        sessionAPI: SessionAPIClientProtocol,
        tokens: AuthTokenStoreProtocol
    ) {
        self.api = api
        self.sessionAPI = sessionAPI
        self.tokens = tokens
    }

    public func listSessions(
        cursor: String? = nil,
        size: Int? = nil
    ) async throws -> SessionHistoryPage {
        let accessToken = try await requireAccessToken()
        return try await api.listSessions(accessToken: accessToken, cursor: cursor, size: size)
    }

    public func sessionDetail(sessionID: String) async throws -> SessionDetail {
        let accessToken = try await requireAccessToken()
        return try await api.getSessionDetail(sessionID: sessionID, accessToken: accessToken)
    }

    // Both helpers are duplicated per client in this repository rather than
    // shared — same shape as `DefaultCorpusClient` / `DefaultDailyReadClient`.
    // Nothing here is worth being the first to break that.
    private func ensureAccessToken(deviceID: String) async throws -> String {
        if let existing = try await tokens.accessToken(), !existing.isEmpty {
            return existing
        }
        let issued = try await sessionAPI.issueGuest(deviceID: deviceID)
        try await tokens.save(tokens: issued, deviceID: deviceID)
        return issued.accessToken
    }

    private func requireAccessToken() async throws -> String {
        let deviceID = try await tokens.deviceID()
        return try await ensureAccessToken(deviceID: deviceID)
    }
}
