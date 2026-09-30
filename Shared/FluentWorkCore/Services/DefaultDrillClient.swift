import FluentWorkNetworking
import Foundation

/// 闪测（Drill）的数据面，**不带 token**。
///
/// `FluentWorkNetworking` 那一层（`DrillClientProtocol` / `DrillAPIClient`）把 `accessToken`
/// 当参数收；这一层把「要有 token 才发得出去」收进来，中间件因此不需要知道鉴权存在。
/// 与 `DefaultSessionHistoryClient` / `DefaultCorpusClient` 同形。
///
/// 三件事各有出处，不是顺手加的：
/// - `dueRound(size:)` 的 `size` 就是 PRD 的「一轮 10 题」——**由客户端决定一轮几题**，
///   而不是等服务端给多少算多少；
/// - `judge` 的 `responseMS` 必须由客户端量：它是「5 秒限时」的原始读数（服务端只做判定，
///   不知道学员什么时候开始答题）；
/// - `sessionID` 是**可空**的（`drill_records.session_id` 在库里可空）——闪测从某次练习会话
///   打开时带上它，从入口直接进来就是 nil。
public protocol DrillClient: Sendable {
    func dueRound(size: Int) async throws -> DrillRound
    func judge(
        blockID: String,
        asrText: String,
        responseMS: Int,
        sessionID: String?
    ) async throws -> DrillVerdict
    func appeal(recordID: Int64) async throws -> DrillAppealOutcome
}

public final class DefaultDrillClient: DrillClient, Sendable {
    private let api: DrillClientProtocol
    private let sessionAPI: SessionAPIClientProtocol
    private let tokens: AuthTokenStoreProtocol

    public init(
        api: DrillClientProtocol,
        sessionAPI: SessionAPIClientProtocol,
        tokens: AuthTokenStoreProtocol
    ) {
        self.api = api
        self.sessionAPI = sessionAPI
        self.tokens = tokens
    }

    public func dueRound(size: Int) async throws -> DrillRound {
        try await api.dueRound(accessToken: try await requireAccessToken(), size: size)
    }

    public func judge(
        blockID: String,
        asrText: String,
        responseMS: Int,
        sessionID: String?
    ) async throws -> DrillVerdict {
        try await api.judge(
            accessToken: try await requireAccessToken(),
            blockID: blockID,
            asrText: asrText,
            responseMS: responseMS,
            sessionID: sessionID
        )
    }

    public func appeal(recordID: Int64) async throws -> DrillAppealOutcome {
        try await api.appeal(accessToken: try await requireAccessToken(), recordID: recordID)
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
