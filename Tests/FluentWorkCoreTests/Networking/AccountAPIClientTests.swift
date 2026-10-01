import Foundation
import FluentWorkNetworking
import Moya
import Testing

/// 账号密码的两条端点（A1）：`POST /auth/register` 与 `POST /auth/login`。
///
/// 这一组盯的是**请求的形状**，而不是「能不能解出 JSON」——
/// 两条路都不带令牌，而这一点最容易在复制粘贴里丢掉：它们返回的**就是**令牌，
/// 手上那份游客令牌对这个调用没有任何用。
@Test func accountAPIClientRegistersAndLogsInWithoutAToken() async throws {
    let registeredJSON = Data(
        """
        {
          "user_id":"u-42",
          "is_guest":false,
          "status":"active",
          "access_token":"access-42",
          "refresh_token":"refresh-42",
          "token_type":"Bearer",
          "expires_in":3600
        }
        """.utf8
    )

    let client = AccountAPIClient(
        network: StubNetworkClient { target in
            // **两条都不该带 Authorization。**
            #expect(
                target.headers?["Authorization"] == nil,
                "\(target.path) 带了令牌 —— 它返回的就是令牌，带上一份游客令牌没有意义"
            )
            switch target.path {
            case "/auth/register", "/auth/login":
                return registeredJSON
            default:
                Issue.record("unexpected path \(target.path)")
                return Data()
            }
        },
        baseURL: URL(string: "http://127.0.0.1:8080/api/v1")!
    )

    let registered = try await client.registerEmail(
        email: "tango@example.com",
        password: "a good password"
    )
    #expect(registered.accessToken == "access-42")
    #expect(registered.isGuest == false, "注册出来的身份不该被解成游客")

    let signedIn = try await client.loginEmail(
        email: "tango@example.com",
        password: "a good password"
    )
    #expect(signedIn.userID == "u-42")
}

/// 请求体里必须**同时**有邮箱与口令 —— 少一个都会得到一个 400，
/// 而那种错在真机上只表现为「登录失败」，很难查。
@Test func accountAPIClientSendsEmailAndPasswordInTheBody() async throws {
    // 断言写在闭包**里面**：这是一个 `@Sendable` 闭包，捕获可变数组在 Swift 6 下不成立
    // （而且那样做本身也不安全）。两条调用各跑一次闭包体，等于各断言一次。
    let client = AccountAPIClient(
        network: StubNetworkClient { target in
            guard case let .requestParameters(parameters, _) = target.task else {
                Issue.record("\(target.path) 的请求体不是 JSON 参数")
                return Data()
            }
            #expect(
                parameters["email"] as? String == "tango@example.com",
                "\(target.path) 的请求体里没有邮箱"
            )
            #expect(
                parameters["password"] as? String == "a good password",
                "\(target.path) 的请求体里没有口令"
            )
            return Data(
                """
                {"user_id":"u-1","is_guest":false,"status":"active",
                 "access_token":"a","refresh_token":"r","token_type":"Bearer","expires_in":1}
                """.utf8
            )
        },
        baseURL: URL(string: "http://127.0.0.1:8080/api/v1")!
    )

    _ = try await client.registerEmail(email: "tango@example.com", password: "a good password")
    _ = try await client.loginEmail(email: "tango@example.com", password: "a good password")
}
