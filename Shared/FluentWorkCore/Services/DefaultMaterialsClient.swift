import FluentWorkNetworking
import Foundation

/// 素材的种类。**与后端 `internal/materials/model.go` 的 `KindPaste` / `KindSentence` 同值。**
///
/// 只有两种：`url` 那一种（`KindURL`）在服务端是占位实现（`URLPlaceholder`，V1 不抓取），
/// 而 屏 11 的三种输入里没有「贴链接」这一路 —— 写进来会让「怎么还没有」变成一个查不到答案的问题。
public enum MaterialKind: String, Equatable, Sendable {
    case sentence
    case paste
}

public protocol MaterialsClientProtocol: Sendable {
    /// 建一份素材，拿回它的 id。
    ///
    /// 服务端回 202：素材已落库、提炼（refine）还在异步跑。**这不影响调用方** ——
    /// 会话引用的是 id，句子的提炼与它会话内的表现是两件异步的事。
    func createMaterial(kind: MaterialKind, content: String) async throws -> String
}

public final class DefaultMaterialsClient: MaterialsClientProtocol, @unchecked Sendable {
    private let api: MaterialsAPIClientProtocol
    private let sessionAPI: SessionAPIClientProtocol
    private let tokens: AuthTokenStoreProtocol

    public init(
        api: MaterialsAPIClientProtocol,
        sessionAPI: SessionAPIClientProtocol,
        tokens: AuthTokenStoreProtocol
    ) {
        self.api = api
        self.sessionAPI = sessionAPI
        self.tokens = tokens
    }

    public func createMaterial(kind: MaterialKind, content: String) async throws -> String {
        let accessToken = try await requireAccessToken()
        let response = try await api.createMaterial(
            accessToken: accessToken,
            kind: kind.rawValue,
            content: content
        )
        return response.materialID
    }

    private func requireAccessToken() async throws -> String {
        let deviceID = try await tokens.deviceID()
        return try await ensureAccessToken(deviceID: deviceID)
    }

    /// 与另外六个 `Default*Client` 里的同名方法逐字一致 —— 包括**为什么还要在这里再要一次**：
    /// 启动流程可能还没跑完，第一次请求要能自己把游客令牌换成真的。
    private func ensureAccessToken(deviceID: String) async throws -> String {
        if let existing = try await tokens.accessToken(), !existing.isEmpty {
            return existing
        }
        let issued = try await sessionAPI.issueGuest(deviceID: deviceID)
        try await tokens.save(tokens: issued, deviceID: deviceID)
        return issued.accessToken
    }
}
