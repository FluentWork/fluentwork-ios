import FactoryKit
import FluentWorkNetworking
import Foundation
import TGReduxKit

/// 闪测那一轮里所有可取消的任务。
///
/// 全部挂在固定 id 上（不用 `TaskID` 之类按题号派生）：**一轮闪测同时只该有一个取题、
/// 一个判定、一个申诉在飞**，所以「第二次开始」天然应该取消「第一次」。这一层没有长连接，
/// 五条任务全都属于这一轮，退出/失败/结算时一起停。
public enum DrillTaskID {
    public static let fetchRound: CancellationID = "drill.fetch-round"
    public static let judge: CancellationID = "drill.judge"
    public static let appeal: CancellationID = "drill.appeal"
    public static let readiness: CancellationID = "drill.readiness"
    public static let answerDeadline: CancellationID = "drill.answer-deadline"

    public static var all: [CancellationID] {
        [fetchRound, judge, appeal, readiness, answerDeadline]
    }
}

/// 把 `DrillAction` 接到 `DrillRoundMachine` 上。
///
/// 形状抄自 `speechSessionMiddleware`，因为它让同一件事只存在一处：
///
/// 1. 机器是**纯函数**，跑在这里 —— 它要发效应（取题 / 判定 / 申诉 / 定时器），而 reducer 不许
///    有副作用；
/// 2. 算完的新状态经 `.applyRound` 写回 store，`drillReducer` 只做「把结果收下」；
/// 3. 服务端回来的东西（`.roundLoaded` / `.verdictReceived` / …）**也是机器事件**，
///    走同一条路回来 —— 于是「什么时候能进下一题」这样的规则只写在机器里一份。
///
/// 「5 秒限时」这条尤其不能写在视图里：它由机器在 `.answering` 上武装（
/// `scheduleAnswerDeadline`），到点派 `.answerDeadlineReached`，机器带着**截止时长**
/// 提交（`responseMS = answerSeconds * 1000`）。视图只负责把学员说的话交上来。
public func drillMiddleware(container: Container) -> Middleware<AppState, AppAction> {
    let client = container.drillClient()

    return { store, action, next in
        guard case let .drill(drillAction) = action,
            let event = drillAction.roundEvent
        else {
            return next(action)
        }

        // 归因来源只在开始那一轮时更新，之后一路带着走：判定要它，而判定发生在好几步之后。
        let carriedSessionID: String?
        if case let .startTapped(_, sessionID) = drillAction {
            carriedSessionID = sessionID
        } else {
            carriedSessionID = store.state.drill.sourceSessionID
        }

        var round = store.state.drill.round
        let effects = DrillRoundMachine.reduce(&round, event: event)

        let apply = next(.drill(.applyRound(round, sourceSessionID: carriedSessionID)))
        let interpreted = effects.map {
            interpretDrillEffect($0, client: client, sessionID: carriedSessionID)
        }
        return .merge([apply] + interpreted)
    }
}

private func interpretDrillEffect(
    _ effect: DrillRoundEffect,
    client: DrillClient,
    sessionID: String?
) -> Effect<AppAction> {
    switch effect {
    case let .fetchRound(size):
        return .task(id: DrillTaskID.fetchRound) {
            do {
                let round = try await client.dueRound(size: size)
                guard !Task.isCancelled else { return nil }
                return .drill(.roundLoaded(round))
            } catch is CancellationError {
                return nil
            } catch {
                guard !Task.isCancelled else { return nil }
                return .drill(.roundLoadFailed(drillErrorMessage(error)))
            }
        }

    case let .scheduleReadiness(seconds):
        // `.debounce` 自带「到点前被取消就不派」——正是这里要的语义：学员提前跳过时，
        // 那个 1 秒的读数窗口必须自己消失，而不是稍后把已经过期的事件派回来。
        return .debounce(id: DrillTaskID.readiness, delay: .seconds(seconds)) {
            .drill(.readinessElapsed(at: Date()))
        }

    case let .scheduleAnswerDeadline(seconds):
        return .debounce(id: DrillTaskID.answerDeadline, delay: .seconds(seconds)) {
            .drill(.answerDeadlineReached)
        }

    case .cancelTimers:
        return .merge(DrillTaskID.all.map { Effect<AppAction>.cancel(id: $0) })

    case let .submitAttempt(blockID, asrText, responseMS):
        return .task(id: DrillTaskID.judge) {
            do {
                let verdict = try await client.judge(
                    blockID: blockID,
                    asrText: asrText,
                    responseMS: responseMS,
                    sessionID: sessionID
                )
                guard !Task.isCancelled else { return nil }
                return .drill(.verdictReceived(verdict))
            } catch is CancellationError {
                return nil
            } catch {
                guard !Task.isCancelled else { return nil }
                return .drill(.attemptFailed(drillErrorMessage(error)))
            }
        }

    case let .appeal(recordID):
        return .task(id: DrillTaskID.appeal) {
            do {
                let outcome = try await client.appeal(recordID: recordID)
                guard !Task.isCancelled else { return nil }
                return .drill(.appealResolved(outcome))
            } catch is CancellationError {
                return nil
            } catch {
                guard !Task.isCancelled else { return nil }
                return .drill(.attemptFailed(drillErrorMessage(error)))
            }
        }
    }
}

/// 失败说人话。
///
/// ⚠️ 这里此前直接端的是 `error.localizedDescription` —— 于是屏幕上出现过
/// 「The operation couldn't be completed. (FluentWorkCore.TokenError error 0.)」。
/// 那是给开发看的字符串，而这一屏是给学员看的（截图里抓到的那一次就是它）。
/// 与 `accountDataErrorMessage` / `accountAuthErrorMessage` 同一套写法。
func drillErrorMessage(_ error: Error) -> String {
    if let apiError = error as? APIError {
        switch apiError {
        case .network:
            return "网络没通，这一轮没能开始。"
        case .decoding:
            return "这一轮没能开始，请稍后再试。"
        case .cancelled:
            return "这一轮已经取消了。"
        case let .backend(code, message):
            // 空语料是一个**可解释的前置条件**，不是故障：把它说成人话。
            if code.contains("PRECONDITION") || code.contains("EMPTY") || code.contains("NOT_FOUND") {
                return "语料库还是空的 —— 先完成一次「说」，攒下第一句话术块。"
            }
            if !message.isEmpty { return message }
        case .unknown:
            break
        }
    }
    return "这一轮没能开始，请稍后再试。"
}
