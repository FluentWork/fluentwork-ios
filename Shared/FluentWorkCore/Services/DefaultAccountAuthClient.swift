import Foundation
import FluentWorkNetworking

/// 账号密码登录这条链路的**服务面**（屏 15）。
///
/// 它做的是「一句话」：**拿邮箱口令换身份，然后把本机的东西搬过去**。三件事的顺序是实打实的 ——
/// 先拿令牌（没有令牌什么都做不了）→ 令牌落库（否则下一次启动又回到游客）→
/// 再把游客记录并进注册身份（这一步需要**旧令牌**去证明那些记录是谁的）。
/// 视图不该知道这个顺序，中间件也不该自己抄一遍，所以它住在这里。
public protocol AccountAuthClientProtocol: Sendable {
    /// 注册或登录。返回这次拿到的注册身份。
    ///
    /// - Parameter mode: `.register` 会建号（重复邮箱报 409），`.login` 只认已有账号。
    func signIn(mode: AccountAuthMode, email: String, password: String) async throws -> AccountSignInOutcome
}

/// 登录链路真正需要令牌存储做的**四件事**。
///
/// 收窄成一个端口，不是为了好看：`AuthTokenStoreProtocol` 有十来个成员（含刷新协调那一套），
/// 而这条链路只用得上这四个。**声明自己需要什么**，真假件两边都只剩四行。
public protocol AccountTokenPort: Sendable {
    func deviceID() async throws -> String
    func accessToken() async throws -> String?
    func isGuest() async throws -> Bool
    func save(tokens: TokenResponse, deviceID: String) async throws
}

/// 把本机游客的记录并进当前身份。**只有一步**，所以只声明一步。
public protocol GuestMergePort: Sendable {
    func mergeGuest(deviceID: String, guestAccessToken: String) async throws
}

/// 一次登录的结果。**只带屏幕要说的话，不带令牌** ——
/// 令牌进令牌库，不该跟着一个「结果值」在模块之间流动。
public struct AccountSignInOutcome: Equatable, Sendable {
    public var userID: String
    /// 这次登录之前，本机是不是一个**有记录的游客**。
    public var mergedGuestRecords: Bool

    public init(userID: String, mergedGuestRecords: Bool) {
        self.userID = userID
        self.mergedGuestRecords = mergedGuestRecords
    }
}

public final class DefaultAccountAuthClient: AccountAuthClientProtocol, @unchecked Sendable {
    private let api: AccountAPIClientProtocol
    private let merger: GuestMergePort
    private let tokens: AccountTokenPort

    public init(
        api: AccountAPIClientProtocol,
        merger: GuestMergePort,
        tokens: AccountTokenPort
    ) {
        self.api = api
        self.merger = merger
        self.tokens = tokens
    }

    public func signIn(
        mode: AccountAuthMode,
        email: String,
        password: String
    ) async throws -> AccountSignInOutcome {
        // 1) 换身份。
        let issued: TokenResponse
        switch mode {
        case .register:
            issued = try await api.registerEmail(email: email, password: password)
        case .login:
            issued = try await api.loginEmail(email: email, password: password)
        }

        // 2) 把**旧**令牌与设备号读出来 —— 必须在覆盖之前：
        //    合并要的是「那些游客记录属于谁」，而覆盖之后就查不到了。
        let deviceID = try await tokens.deviceID()
        let previousAccessToken = try await tokens.accessToken()
        let wasGuest = (try? await tokens.isGuest()) ?? false

        // 3) 令牌落库。**放在合并之前**：即使合并失败，这次登录本身是真的成了 ——
        //    让用户回到「没登录」会让他以为刚才输的口令是错的。
        try await tokens.save(tokens: issued, deviceID: deviceID)

        // 4) 把本机的游客记录搬过去。
        //
        //    只有「之前是游客 + 手上有旧令牌」才做。**失败不抛错**：登录已经成立，
        //    而合并是尽力而为 —— 把它报成登录失败，等于因为一件后台搬运的事
        //    让学员重新输一遍口令。
        var merged = false
        if wasGuest, let previousAccessToken, !previousAccessToken.isEmpty {
            do {
                try await merger.mergeGuest(
                    deviceID: deviceID,
                    guestAccessToken: previousAccessToken
                )
                merged = true
            } catch {
                merged = false
            }
        }

        return AccountSignInOutcome(userID: issued.userID, mergedGuestRecords: merged)
    }
}


// MARK: - 生产适配

/// 把令牌存储接成端口。
///
/// ⚠️ 这里必须是**适配器**而不是给 `SecureAuthTokenStore` 加一个空扩展：
/// `any AuthTokenStoreProtocol` 这个存在类型**不会**因为具体类型满足了 `AccountTokenPort`
/// 就跟着满足（协议的一致性不沿着存在类型传播），而容器工厂交出来的正是存在类型。
public struct AuthTokenStoreAdapter: AccountTokenPort {
    private let store: AuthTokenStoreProtocol

    public init(store: AuthTokenStoreProtocol) {
        self.store = store
    }

    public func deviceID() async throws -> String { try await store.deviceID() }
    public func accessToken() async throws -> String? { try await store.accessToken() }
    public func isGuest() async throws -> Bool { try await store.isGuest() }
    public func save(tokens: TokenResponse, deviceID: String) async throws {
        try await store.save(tokens: tokens, deviceID: deviceID)
    }
}

/// 把 `SessionAPIClient` 的合并那一招接成端口。
///
/// 适配只有一行：合并的请求形状是会话客户端的知识，而这条链路只想知道「有没有并成功」。
public struct SessionGuestMergeAdapter: GuestMergePort {
    private let sessionAPI: SessionAPIClientProtocol

    public init(sessionAPI: SessionAPIClientProtocol) {
        self.sessionAPI = sessionAPI
    }

    public func mergeGuest(deviceID: String, guestAccessToken: String) async throws {
        _ = try await sessionAPI.mergeGuestAccount(
            deviceID: deviceID,
            accessToken: guestAccessToken
        )
    }
}
