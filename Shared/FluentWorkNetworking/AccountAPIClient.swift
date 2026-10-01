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
        do {
            return try JSONDecoder().decode(DeleteAccountDataResponse.self, from: data)
        } catch {
            throw APIError.decoding(description: error.localizedDescription)
        }
    }
}
