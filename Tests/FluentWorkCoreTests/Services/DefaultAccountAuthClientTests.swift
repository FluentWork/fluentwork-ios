import FluentWorkCore
import FluentWorkNetworking
import Foundation
import Testing

/// 登录链路的服务面：**换身份 → 令牌落库 → 把本机游客记录搬过去**。
///
/// 这一组判据盯的是**三步的顺序**。顺序错了不会报错，只会丢东西 ——
/// 而那正是这条链路上唯一无法挽回的事。
@Suite("账号登录链路的顺序")
struct DefaultAccountAuthClientTests {

    // MARK: - 假件

    private actor FakeTokenStore: AccountTokenPort {
        private var device = "device-1"
        private var token: String?
        private var guest: Bool
        private(set) var savedCount = 0

        init(accessToken: String?, isGuest: Bool) {
            self.token = accessToken
            self.guest = isGuest
        }

        func deviceID() async throws -> String { device }
        func accessToken() async throws -> String? { token }
        func isGuest() async throws -> Bool { guest }
        func save(tokens: TokenResponse, deviceID: String) async throws {
            savedCount += 1
            token = tokens.accessToken
            guest = tokens.isGuest
        }
        func currentToken() -> String? { token }
    }

    private final class FakeAccountAPI: AccountAPIClientProtocol, @unchecked Sendable {
        var registerResult: Result<TokenResponse, Error>
        var loginResult: Result<TokenResponse, Error>
        private(set) var registeredEmails: [String] = []

        init(
            registerResult: Result<TokenResponse, Error> = .failure(TestError.unset),
            loginResult: Result<TokenResponse, Error> = .failure(TestError.unset)
        ) {
            self.registerResult = registerResult
            self.loginResult = loginResult
        }

        func registerEmail(email: String, password: String) async throws -> TokenResponse {
            registeredEmails.append(email)
            return try registerResult.get()
        }

        func loginEmail(email: String, password: String) async throws -> TokenResponse {
            try loginResult.get()
        }

        func deleteAllMyData(accessToken: String) async throws -> DeleteAccountDataResponse {
            throw TestError.unset
        }
    }

    private final class FakeMerger: GuestMergePort, @unchecked Sendable {
        private(set) var mergeCalls: [(deviceID: String, accessToken: String)] = []
        var mergeShouldFail = false

        func mergeGuest(deviceID: String, guestAccessToken: String) async throws {
            mergeCalls.append((deviceID, guestAccessToken))
            if mergeShouldFail { throw TestError.unset }
        }
    }

    private enum TestError: Error { case unset }

    private func registeredTokens(userID: String = "u-42") -> TokenResponse {
        TokenResponse(
            userID: userID,
            isGuest: false,
            status: "active",
            accessToken: "access-new",
            refreshToken: "refresh-new",
            tokenType: "Bearer",
            expiresIn: 3600
        )
    }

    // MARK: - 顺序

    /// **旧的游客令牌必须在覆盖之前读到** —— 合并要的是「那些记录原来属于谁」。
    @Test func 合并用的是覆盖之前的旧令牌() async throws {
        let store = FakeTokenStore(accessToken: "access-guest", isGuest: true)
        let api = FakeAccountAPI(loginResult: .success(registeredTokens()))
        let session = FakeMerger()
        let client = DefaultAccountAuthClient(api: api, merger: session, tokens: store)

        let outcome = try await client.signIn(
            mode: .login, email: "tango@example.com", password: "pw"
        )

        #expect(outcome.userID == "u-42")
        #expect(outcome.mergedGuestRecords)
        #expect(session.mergeCalls.count == 1)
        #expect(
            session.mergeCalls.first?.accessToken == "access-guest",
            "合并用了新令牌 —— 那些游客记录不认它，数据会留在原地"
        )
        #expect(await store.currentToken() == "access-new")
    }

    /// 注册走的是注册那条路（不是登录）—— 建号失败（409）要能被抛出来。
    @Test func 注册模式调注册端点() async throws {
        let store = FakeTokenStore(accessToken: nil, isGuest: true)
        let api = FakeAccountAPI(registerResult: .success(registeredTokens()))
        let client = DefaultAccountAuthClient(api: api, merger: FakeMerger(), tokens: store)

        _ = try await client.signIn(mode: .register, email: "tango@example.com", password: "pw")
        #expect(api.registeredEmails == ["tango@example.com"])
    }

    // MARK: - 合并是尽力而为

    /// **合并失败不能让登录失败。**
    ///
    /// 登录已经成立（令牌拿到了也存下了），而合并是后台搬运。
    /// 把它报成登录失败，等于因为一件搬运的事让学员重新输一遍口令。
    @Test func 合并失败不影响登录成立() async throws {
        let store = FakeTokenStore(accessToken: "access-guest", isGuest: true)
        let api = FakeAccountAPI(loginResult: .success(registeredTokens()))
        let session = FakeMerger()
        session.mergeShouldFail = true
        let client = DefaultAccountAuthClient(api: api, merger: session, tokens: store)

        let outcome = try await client.signIn(mode: .login, email: "tango@example.com", password: "pw")

        #expect(outcome.mergedGuestRecords == false, "合并失败了却报成成功")
        #expect(outcome.userID == "u-42", "登录本身应当成立")
        #expect(await store.currentToken() == "access-new", "令牌没有落库 —— 下次启动又回到游客")
    }

    /// 本来就是注册用户（不是游客）时**不该调合并**：没有什么可并的，
    /// 而多调一次会把另一个人的记录搬过来（那是设备号撞了才会发生的事）。
    @Test func 非游客不调合并() async throws {
        let store = FakeTokenStore(accessToken: "access-registered", isGuest: false)
        let api = FakeAccountAPI(loginResult: .success(registeredTokens()))
        let session = FakeMerger()
        let client = DefaultAccountAuthClient(api: api, merger: session, tokens: store)

        let outcome = try await client.signIn(mode: .login, email: "tango@example.com", password: "pw")

        #expect(outcome.mergedGuestRecords == false)
        #expect(session.mergeCalls.isEmpty, "非游客也去合并了")
    }

    /// 手上一份令牌都没有时也不调合并（合并需要旧令牌）。
    @Test func 没有旧令牌时不调合并() async throws {
        let store = FakeTokenStore(accessToken: nil, isGuest: true)
        let api = FakeAccountAPI(loginResult: .success(registeredTokens()))
        let session = FakeMerger()
        let client = DefaultAccountAuthClient(api: api, merger: session, tokens: store)

        _ = try await client.signIn(mode: .login, email: "tango@example.com", password: "pw")
        #expect(session.mergeCalls.isEmpty)
    }

    /// 返回的结果里**不带令牌** —— 令牌只进令牌库，不跟着结果值在模块之间流动。
    @Test func 结果里没有令牌() async throws {
        let store = FakeTokenStore(accessToken: nil, isGuest: false)
        let api = FakeAccountAPI(loginResult: .success(registeredTokens()))
        let client = DefaultAccountAuthClient(api: api, merger: FakeMerger(), tokens: store)

        let outcome = try await client.signIn(mode: .login, email: "e@example.com", password: "pw")
        let mirror = Mirror(reflecting: outcome)
        let fields = mirror.children.compactMap(\.label)
        #expect(fields == ["userID", "mergedGuestRecords"], "结果里多带了东西：\(fields)")
    }
}
