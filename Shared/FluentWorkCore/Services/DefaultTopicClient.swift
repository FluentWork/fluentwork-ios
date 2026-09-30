import FluentWorkNetworking
import Foundation

/// 话题卡的数据面，**不带 token**（与 `DefaultSessionHistoryClient` / `DefaultDrillClient` 同形）。
public protocol TopicClient: Sendable {
    func todayCards() async throws -> [TopicCard]
    func checkin(
        cardID: String,
        reflection: String,
        usedBlockIDs: [String]
    ) async throws -> TopicCheckinResult
    func stats(days: Int?) async throws -> TopicPracticeStats
    func dismiss(cardID: String, reason: TopicDismissReason) async throws -> TopicDismissResult
}

public final class DefaultTopicClient: TopicClient, Sendable {
    private let api: TopicClientProtocol
    private let sessionAPI: SessionAPIClientProtocol
    private let tokens: AuthTokenStoreProtocol

    public init(
        api: TopicClientProtocol,
        sessionAPI: SessionAPIClientProtocol,
        tokens: AuthTokenStoreProtocol
    ) {
        self.api = api
        self.sessionAPI = sessionAPI
        self.tokens = tokens
    }

    public func todayCards() async throws -> [TopicCard] {
        try await api.cards(accessToken: try await requireAccessToken())
    }

    public func checkin(
        cardID: String,
        reflection: String,
        usedBlockIDs: [String]
    ) async throws -> TopicCheckinResult {
        try await api.checkin(
            accessToken: try await requireAccessToken(),
            cardID: cardID,
            request: TopicCheckinRequest(reflection: reflection, usedBlockIDs: usedBlockIDs)
        )
    }

    public func stats(days: Int?) async throws -> TopicPracticeStats {
        try await api.stats(accessToken: try await requireAccessToken(), days: days)
    }

    public func dismiss(cardID: String, reason: TopicDismissReason) async throws -> TopicDismissResult {
        try await api.dismiss(
            accessToken: try await requireAccessToken(),
            cardID: cardID,
            reason: reason
        )
    }

    // Both helpers are duplicated per client in this repository rather than shared
    // — same shape (and same reason) as `DefaultSessionHistoryClient`.
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
