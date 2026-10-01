import Foundation
import Moya

/// 素材（`/materials`）的 REST 表面。
///
/// 单独一个 client 而不是塞进 `SessionAPIClient`：它对应后端**另一个模块**
/// （`internal/materials`），而那个模块有自己的生命周期 —— 素材先建、提炼异步进行、
/// 会话只是引用它的 id。把两件事并进一个 client 会让「谁的失败算谁的」变得含糊。
public protocol MaterialsAPIClientProtocol: Sendable {
    func createMaterial(
        accessToken: String,
        kind: String,
        content: String
    ) async throws -> CreateMaterialResponse
}

public final class MaterialsAPIClient: MaterialsAPIClientProtocol, Sendable {
    private let network: NetworkClientProtocol
    private let baseURL: URL

    public init(network: NetworkClientProtocol, baseURL: URL) {
        self.network = network
        self.baseURL = baseURL
    }

    public func createMaterial(
        accessToken: String,
        kind: String,
        content: String
    ) async throws -> CreateMaterialResponse {
        let data = try await network.requestData(
            for: AbsoluteFluentWorkTarget(
                baseURL: baseURL,
                api: .createMaterial(accessToken: accessToken, kind: kind, content: content)
            )
        )
        do {
            return try JSONDecoder().decode(CreateMaterialResponse.self, from: data)
        } catch {
            throw APIError.decoding(description: error.localizedDescription)
        }
    }
}
