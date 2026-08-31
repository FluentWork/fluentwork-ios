import Foundation

public protocol CorpusAPIClientProtocol: Sendable {
    func listBlocks(
        accessToken: String,
        scene: String?,
        function: String?,
        keyword: String?,
        cursor: String?,
        updatedAfter: String?,
        limit: Int?,
        favoriteOnly: Bool
    ) async throws -> ListPhraseBlocksResponse
    func batchAccept(
        accessToken: String,
        sourceSessionID: String,
        blocks: [CorpusBatchAcceptBlockRequest]
    ) async throws -> BatchAcceptBlocksResponse
    func updateBlock(
        accessToken: String,
        blockID: String,
        request: UpdateCorpusBlockRequest
    ) async throws -> PhraseBlock
    func deleteBlock(accessToken: String, blockID: String) async throws -> DeleteCorpusBlockResponse
    func favoriteBlock(
        accessToken: String,
        blockID: String,
        isFavorite: Bool,
        pinned: Bool
    ) async throws -> PhraseBlock
}

public final class CorpusAPIClient: CorpusAPIClientProtocol, Sendable {
    private let network: NetworkClientProtocol
    private let baseURL: URL

    public init(network: NetworkClientProtocol, baseURL: URL) {
        self.network = network
        self.baseURL = baseURL
    }

    public func listBlocks(
        accessToken: String,
        scene: String? = nil,
        function: String? = nil,
        keyword: String? = nil,
        cursor: String? = nil,
        updatedAfter: String? = nil,
        limit: Int? = nil,
        favoriteOnly: Bool = false
    ) async throws -> ListPhraseBlocksResponse {
        try await decode(
            ListPhraseBlocksResponse.self,
            .listCorpusBlocks(
                accessToken: accessToken,
                scene: scene,
                function: function,
                keyword: keyword,
                cursor: cursor,
                updatedAfter: updatedAfter,
                limit: limit,
                favoriteOnly: favoriteOnly
            )
        )
    }

    public func batchAccept(
        accessToken: String,
        sourceSessionID: String,
        blocks: [CorpusBatchAcceptBlockRequest]
    ) async throws -> BatchAcceptBlocksResponse {
        try await decode(
            BatchAcceptBlocksResponse.self,
            .batchAcceptCorpusBlocks(
                accessToken: accessToken,
                sourceSessionID: sourceSessionID,
                blocks: blocks
            )
        )
    }

    public func updateBlock(
        accessToken: String,
        blockID: String,
        request: UpdateCorpusBlockRequest
    ) async throws -> PhraseBlock {
        try await decode(
            PhraseBlock.self,
            .updateCorpusBlock(
                accessToken: accessToken,
                blockID: blockID,
                request: request
            )
        )
    }

    public func deleteBlock(accessToken: String, blockID: String) async throws -> DeleteCorpusBlockResponse {
        try await decode(
            DeleteCorpusBlockResponse.self,
            .deleteCorpusBlock(accessToken: accessToken, blockID: blockID)
        )
    }

    public func favoriteBlock(
        accessToken: String,
        blockID: String,
        isFavorite: Bool,
        pinned: Bool
    ) async throws -> PhraseBlock {
        try await decode(
            PhraseBlock.self,
            .favoriteCorpusBlock(
                accessToken: accessToken,
                blockID: blockID,
                isFavorite: isFavorite,
                pinned: pinned
            )
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
