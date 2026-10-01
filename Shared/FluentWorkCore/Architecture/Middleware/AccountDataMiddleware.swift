import FactoryKit
import FluentWorkNetworking
import Foundation
import TGReduxKit

/// 「删除我的全部素材」这条链路的中间件（屏 12 的「隐私与数据」）。
///
/// 它做的只有一件事：**把「确定」变成一次请求**。而它为什么必须在中间件而不是视图里 ——
/// 这一步**不可逆**，视图回调只该派一个 action；真正发请求的地方要唯一、
/// 要能带取消、要能把失败说回屏幕上。
public func accountDataMiddleware(container: Container) -> Middleware<AppState, AppAction> {
    let client = container.accountDataClient()

    return { store, action, next in
        guard case .accountData(.confirmed) = action else {
            return next(action)
        }

        // 相位必须已经是 `.confirming`（reducer 里那条守卫的**第二次**确认）。
        // 在中间件里再判一次不是重复：reducer 守的是状态机，
        // 这里守的是「请求真的发出去」那一下 —— 顺序上 reducer 先跑，但这条链路上
        // 少一道就只剩一道，而它挡的是不可逆操作。
        guard store.state.accountData.phase == .deleting else {
            return next(action)
        }

        return .merge(
            next(action),
            .task(id: AppTaskID.accountDataDelete) {
                do {
                    let response = try await client.deleteAllMyData()
                    guard !Task.isCancelled else { return nil }
                    return .accountData(.deleteSucceeded(response))
                } catch is CancellationError {
                    return nil
                } catch {
                    guard !Task.isCancelled else { return nil }
                    return .accountData(.deleteFailed(accountDataErrorMessage(error)))
                }
            }
        )
    }
}

/// 失败说人话。**不把 `localizedDescription` 直接端上去**：那串东西里通常是
/// URLSession 的 domain + code，学员读不出「我该做什么」。
func accountDataErrorMessage(_ error: Error) -> String {
    if let apiError = error as? APIError {
        switch apiError {
        case let .decoding(description):
            return "删除请求已经发出，但回执读不出来（\(description)）。请到语料库确认数据是否已经不在了。"
        case let .network(description):
            return "网络没通（\(description)）。数据没有被删除，可以稍后再试。"
        default:
            break
        }
    }
    return "删除没成功。数据没有被删除，可以稍后再试。"
}
