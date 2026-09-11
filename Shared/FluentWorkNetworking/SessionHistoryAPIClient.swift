import Foundation

/// The conversation list (backend B24).
public protocol SessionHistoryAPIClientProtocol: Sendable {
    func listSessions(
        accessToken: String,
        cursor: String?,
        size: Int?
    ) async throws -> SessionHistoryPage
}

public final class SessionHistoryAPIClient: SessionHistoryAPIClientProtocol, Sendable {
    private let network: NetworkClientProtocol
    private let baseURL: URL

    public init(network: NetworkClientProtocol, baseURL: URL) {
        self.network = network
        self.baseURL = baseURL
    }

    public func listSessions(
        accessToken: String,
        cursor: String? = nil,
        size: Int? = nil
    ) async throws -> SessionHistoryPage {
        let data = try await network.requestData(
            for: AbsoluteFluentWorkTarget(
                baseURL: baseURL,
                api: .listSessions(accessToken: accessToken, cursor: cursor, size: size)
            )
        )
        do {
            return try SessionHistoryJSON.makeDecoder().decode(SessionHistoryPage.self, from: data)
        } catch {
            throw APIError.decoding(description: error.localizedDescription)
        }
    }
}
