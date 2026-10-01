import Foundation
import FluentWorkNetworking

/// 「删除我的全部数据」这条链路的服务面（屏 12）。
///
/// 单独一层而不是让中间件直接拿 `AccountAPIClient`：**令牌的取法**与另外七个
/// `Default*Client` 逐字一致（第一次请求要能自己把游客令牌换成真的），
/// 而那件事不该在中间件里再抄一遍。
public protocol AccountDataClientProtocol: Sendable {
    /// 删掉我自己的全部数据（A4）。**不可逆**。
    func deleteAllMyData() async throws -> DeleteAccountDataResponse
}

public final class DefaultAccountDataClient: AccountDataClientProtocol, @unchecked Sendable {
    private let api: AccountAPIClientProtocol
    private let sessionAPI: SessionAPIClientProtocol
    private let tokens: AuthTokenStoreProtocol

    public init(
        api: AccountAPIClientProtocol,
        sessionAPI: SessionAPIClientProtocol,
        tokens: AuthTokenStoreProtocol
    ) {
        self.api = api
        self.sessionAPI = sessionAPI
        self.tokens = tokens
    }

    public func deleteAllMyData() async throws -> DeleteAccountDataResponse {
        let accessToken = try await requireAccessToken()
        return try await api.deleteAllMyData(accessToken: accessToken)
    }

    private func requireAccessToken() async throws -> String {
        let deviceID = try await tokens.deviceID()
        return try await ensureAccessToken(deviceID: deviceID)
    }

    /// 与另外七个 `Default*Client` 里的同名方法逐字一致 —— 包括**为什么还要在这里再要一次**：
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
