import Foundation
import Moya

/// 账号级数据操作（`/account/*`）的 REST 表面。
///
/// 单独一个 client，理由与 `MaterialsAPIClient` 相同：它对应后端**另一个模块**
/// （`internal/account`），而且它做的是**不可逆**的事 —— 与会话、语料库这些日常读写
/// 混在一个类型里，会让「这一次调用会不会删东西」需要读到最后一行才知道。
public protocol AccountAPIClientProtocol: Sendable {
    /// 删掉我自己的全部数据（A4）。**不可逆**（软删 + 备份保留期）。
    func deleteAllMyData(accessToken: String) async throws -> DeleteAccountDataResponse

    /// 账号密码注册（A1）。返回**注册身份**的令牌（`isGuest == false`）。
    ///
    /// 放在这个 client 而不是 `SessionAPIClient`：这两条端点在后端属于
    /// `internal/account` 模块，而这里的边界就是照着后端模块划的。
    /// （顺带一个实证：往 `SessionAPIClientProtocol` 上加方法会一次打破**四个**既有测试桩 ——
    /// 协议加宽是有代价的，代价落在哪就该在哪划界。）
    func registerEmail(email: String, password: String) async throws -> TokenResponse

    /// 账号密码登录（A1）。
    ///
    /// ⚠️ 两种失败（邮箱不存在 / 口令不对）服务端给**同一句话**，客户端不要试图分辨 ——
    /// 那是服务端**有意**不提供的信息（分开报错等于送一个免费的账号枚举器）。
    func loginEmail(email: String, password: String) async throws -> TokenResponse
}

public final class AccountAPIClient: AccountAPIClientProtocol, Sendable {

    /// 契约要求的那一次确认（`openapi-v1.yaml` 的 `/account/data`：`Must be DELETE-MY-DATA`）。
    ///
    /// 它是**这一个类型**的常量，因为「删数据要带哪一句话」是这个调用自己的规则。
    /// 请求构造器只负责把调用方给的字符串放进 body —— 那样「有没有确认」在类型上看得见。
    public static let confirmationCode = "DELETE-MY-DATA"

    private let network: NetworkClientProtocol
    private let baseURL: URL

    public init(network: NetworkClientProtocol, baseURL: URL) {
        self.network = network
        self.baseURL = baseURL
    }

    public func registerEmail(email: String, password: String) async throws -> TokenResponse {
        try await decode(TokenResponse.self, .registerEmail(email: email, password: password))
    }

    public func loginEmail(email: String, password: String) async throws -> TokenResponse {
        try await decode(TokenResponse.self, .loginEmail(email: email, password: password))
    }

    public func deleteAllMyData(accessToken: String) async throws -> DeleteAccountDataResponse {
        let data = try await network.requestData(
            for: AbsoluteFluentWorkTarget(
                baseURL: baseURL,
                api: .deleteMyData(
                    accessToken: accessToken,
                    confirmationCode: Self.confirmationCode
                )
            )
        )
        return try decode(DeleteAccountDataResponse.self, from: data)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ target: FluentWorkAPI) async throws -> T {
        let data = try await network.requestData(
            for: AbsoluteFluentWorkTarget(baseURL: baseURL, api: target)
        )
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(description: error.localizedDescription)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(description: error.localizedDescription)
        }
    }
}
