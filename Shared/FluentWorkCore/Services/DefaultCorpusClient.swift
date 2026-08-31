import FluentWorkNetworking
import Foundation

public protocol CorpusClientProtocol: Sendable {
    func listBlocks(
        cursor: String?,
        updatedAfter: String?,
        limit: Int?,
        favoriteOnly: Bool
    ) async throws -> ListPhraseBlocksResponse
    func setFavorite(
        blockID: String,
        isFavorite: Bool,
        pinned: Bool
    ) async throws -> PhraseBlock
    func deleteBlock(blockID: String) async throws
    func batchAccept(
        sourceSessionID: String,
        cards: [RefineCard]
    ) async throws -> BatchAcceptBlocksResponse
}

public final class DefaultCorpusClient: CorpusClientProtocol, @unchecked Sendable {
    private let api: CorpusAPIClientProtocol
    private let sessionAPI: SessionAPIClientProtocol
    private let tokens: AuthTokenStoreProtocol

    public init(
        api: CorpusAPIClientProtocol,
        sessionAPI: SessionAPIClientProtocol,
        tokens: AuthTokenStoreProtocol
    ) {
        self.api = api
        self.sessionAPI = sessionAPI
        self.tokens = tokens
    }

    public func listBlocks(
        cursor: String? = nil,
        updatedAfter: String? = nil,
        limit: Int? = nil,
        favoriteOnly: Bool = false
    ) async throws -> ListPhraseBlocksResponse {
        let accessToken = try await requireAccessToken()
        return try await api.listBlocks(
            accessToken: accessToken,
            scene: nil,
            function: nil,
            keyword: nil,
            cursor: cursor,
            updatedAfter: updatedAfter,
            limit: limit,
            favoriteOnly: favoriteOnly
        )
    }

    public func setFavorite(
        blockID: String,
        isFavorite: Bool,
        pinned: Bool
    ) async throws -> PhraseBlock {
        let accessToken = try await requireAccessToken()
        return try await api.favoriteBlock(
            accessToken: accessToken,
            blockID: blockID,
            isFavorite: isFavorite,
            pinned: pinned
        )
    }

    public func deleteBlock(blockID: String) async throws {
        let accessToken = try await requireAccessToken()
        _ = try await api.deleteBlock(accessToken: accessToken, blockID: blockID)
    }

    public func batchAccept(
        sourceSessionID: String,
        cards: [RefineCard]
    ) async throws -> BatchAcceptBlocksResponse {
        let accessToken = try await requireAccessToken()
        let blocks = cards.map {
            CorpusBatchAcceptBlockRequest(
                intentZH: $0.intentZH,
                expressionEN: $0.expressionEN,
                anchorUserSaid: $0.anchorUserSaid,
                sceneTag: $0.sceneTag,
                functionTag: $0.functionTag
            )
        }
        return try await api.batchAccept(
            accessToken: accessToken,
            sourceSessionID: sourceSessionID,
            blocks: blocks
        )
    }

    private func ensureAccessToken(deviceID: String) async throws -> String {
        if let existing = try tokens.accessToken(), !existing.isEmpty {
            return existing
        }
        let issued = try await sessionAPI.issueGuest(deviceID: deviceID)
        try tokens.save(tokens: issued, deviceID: deviceID)
        return issued.accessToken
    }

    private func requireAccessToken() async throws -> String {
        let deviceID = try tokens.deviceID()
        return try await ensureAccessToken(deviceID: deviceID)
    }
}
