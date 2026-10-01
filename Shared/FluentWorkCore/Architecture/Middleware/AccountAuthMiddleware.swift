import FactoryKit
import FluentWorkNetworking
import Foundation
import TGReduxKit

/// 账号密码那条链路的中间件（屏 15）。
///
/// 它做两件事，分两拍：**换身份**（一次调用，里面含令牌落库与搬记录）→ **把身份交给状态机**
/// （`.auth(.mergedIntoRegistered(...))`，那条反应链早就写好了：语料库重建 ＋ 缓存换作用域）。
///
/// 为什么分两拍而不是一拍全干完：`Effect.task` 只能产出一个动作，
/// 而这两拍之间**本来就有语义边界** —— 前一拍是「请求」，后一拍是「状态转移」。
/// 硬塞进一拍就得在别处再补一次派发，反而更难读。
public func accountAuthMiddleware(container: Container) -> Middleware<AppState, AppAction> {
    let client = container.accountAuthClient()
    let tokens = container.authTokenStore()

    return { store, action, next in
        switch action {
        case .accountAuth(.submitTapped):
            // 规则由 `state.canSubmit` 判过（reducer 里也再守一次）——
            // 这里只负责「把已经定下来的事做掉」。
            guard store.state.accountAuth.canSubmit else { return next(action) }
            let mode = store.state.accountAuth.mode
            let email = store.state.accountAuth.email
            let password = store.state.accountAuth.password

            return .merge(
                next(action),
                .task(id: AppTaskID.accountAuthSubmit) {
                    do {
                        _ = try await client.signIn(mode: mode, email: email, password: password)
                        guard !Task.isCancelled else { return nil }
                        return .accountAuth(.succeeded)
                    } catch is CancellationError {
                        return nil
                    } catch {
                        guard !Task.isCancelled else { return nil }
                        return .accountAuth(.failed(accountAuthErrorMessage(error)))
                    }
                }
            )

        case .accountAuth(.succeeded):
            // 令牌已经落库（`signIn` 里存的），所以这里读得到**新的**身份。
            // 读不到就什么都不派 —— 那说明成功信号是凭空来的。
            return .merge(
                next(action),
                .task(id: AppTaskID.accountAuthAdoptIdentity) {
                    guard let userID = try? await tokens.userID(), !userID.isEmpty else {
                        return nil
                    }
                    let deviceID = try? await tokens.deviceID()
                    return .auth(.mergedIntoRegistered(userID: userID, deviceID: deviceID))
                }
            )

        default:
            return next(action)
        }
    }
}

/// 失败说人话。**不把 `localizedDescription` 端上去**（那是给开发看的）。
///
/// 两条凭据失败（邮箱不存在 / 口令不对）服务端给的是同一句话，这里**照样只有一句** ——
/// 客户端不替服务端把差别补回来。
func accountAuthErrorMessage(_ error: Error) -> String {
    if let apiError = error as? APIError {
        switch apiError {
        case .decoding:
            return "登录没成功，请稍后再试。"
        case .network:
            return "网络没通，请检查网络后重试。"
        default:
            break
        }
    }
    // 服务端会回两条：重复注册（409 ALREADY_EXISTS）与凭据不对（401 UNAUTHENTICATED）。
    // 客户端只把它们翻成句子，**不重新编语义** —— 尤其不把 401 拆成「邮箱不存在」与
    // 「口令不对」两种说法（那是服务端有意不提供的信息）。
    if let apiError = error as? APIError, case let .backend(code, message) = apiError {
        if code.contains("ALREADY_EXISTS") || code.contains("CONFLICT") {
            return "这个邮箱已经注册过了"
        }
        if code.contains("UNAUTHENTICATED") {
            return accountAuthRejectedMessage
        }
        if !message.isEmpty { return message }
    }
    return accountAuthRejectedMessage
}
