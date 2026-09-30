import FactoryKit
import FluentWorkNetworking
import Foundation
import TGReduxKit

public enum TopicTaskID {
    public static let cards: CancellationID = "topic.cards"
    public static let stats: CancellationID = "topic.stats"

    /// 一卡一条：换一张卡不该取消上一张的打卡。
    public static func checkin(cardID: String) -> CancellationID {
        CancellationID("topic.checkin.\(cardID)")
    }

    public static func dismiss(cardID: String) -> CancellationID {
        CancellationID("topic.dismiss.\(cardID)")
    }
}

/// 话题卡的数据接线（H1 列表 / H3 打卡 / 86_ M11 忽略）。
///
/// 比 `drillMiddleware` 薄：这一屏没有机器、没有定时器，只有「取 / 送 / 记」。
/// 一条与别处**不同**的地方，写在 `checkinTapped` 那一段里（in-flight 的置位时机）。
public func topicMiddleware(container: Container) -> Middleware<AppState, AppAction> {
    let client = container.topicClient()

    return { store, action, next in
        guard case let .topic(topicAction) = action else {
            return next(action)
        }

        switch topicAction {
        case .appear, .refreshRequested:
            let base = next(action)
            return .merge(base, loadCards(client: client), loadStats(client: client))

        case let .checkinTapped(cardID):
            // 用**动作前**的状态判断。`.checkinTapped` 的 reducer 会把这张卡置成「进行中」，
            // 所以这里读到的假值就是「已经打过卡 / 已经在飞」。
            guard store.state.topic.canCheckIn(cardID) else {
                return next(action)
            }
            // 草稿与要送上去的清单都取自**同一个快照**：分两次读状态，界面上勾掉一条
            // 而请求带的是上一次的清单，这类漂移在单测里看不出来、在真机上很难复现。
            let reflection = store.state.topic.draft(for: cardID).reflection
            let usedBlockIDs = store.state.topic.usedBlockIDs(for: cardID)

            let base = next(action)
            return .merge(
                base,
                .task(id: TopicTaskID.checkin(cardID: cardID)) {
                    do {
                        let result = try await client.checkin(
                            cardID: cardID,
                            reflection: reflection,
                            usedBlockIDs: usedBlockIDs
                        )
                        guard !Task.isCancelled else { return nil }
                        return .topic(.checkinSucceeded(cardID: cardID, result: result))
                    } catch is CancellationError {
                        return nil
                    } catch {
                        guard !Task.isCancelled else { return nil }
                        return .topic(
                            .checkinFailed(cardID: cardID, message: error.localizedDescription)
                        )
                    }
                }
            )

        case let .dismissTapped(cardID, reason):
            guard store.state.topic.canDismiss(cardID) else {
                return next(action)
            }
            let base = next(action)
            return .merge(
                base,
                .task(id: TopicTaskID.dismiss(cardID: cardID)) {
                    do {
                        _ = try await client.dismiss(cardID: cardID, reason: reason)
                        guard !Task.isCancelled else { return nil }
                        // 服务端的 `already_dismissed` 不进状态：**忽略是幂等的**，
                        // 两次忽略与一次忽略对学员是同一件事，把它显示出来只会让人以为出了错。
                        return .topic(.dismissSucceeded(cardID: cardID, reason: reason))
                    } catch is CancellationError {
                        return nil
                    } catch {
                        guard !Task.isCancelled else { return nil }
                        return .topic(
                            .dismissFailed(cardID: cardID, message: error.localizedDescription)
                        )
                    }
                }
            )

        case .cardsLoaded, .cardsFailed, .statsLoaded,
            .checkinDraftReflectionChanged, .checkinDraftBlockToggled, .checkinDraftDiscarded,
            .checkinSucceeded, .checkinFailed,
            .dismissSucceeded, .dismissFailed:
            return next(action)
        }
    }
}

/// 今天的卡。**空不是错误**，所以这里不把空列表转成失败 —— 相位由 reducer 按
/// 「有没有卡」决定（`.empty` vs `.ready`）。
private func loadCards(client: TopicClient) -> Effect<AppAction> {
    .task(id: TopicTaskID.cards) {
        do {
            let cards = try await client.todayCards()
            guard !Task.isCancelled else { return nil }
            return .topic(.cardsLoaded(cards))
        } catch is CancellationError {
            return nil
        } catch {
            guard !Task.isCancelled else { return nil }
            return .topic(.cardsFailed(error.localizedDescription))
        }
    }
}

/// 统计是**附加信息**：它失败不该让整屏变成错误页，所以回来只写 `stats` 一个字段。
private func loadStats(client: TopicClient) -> Effect<AppAction> {
    .task(id: TopicTaskID.stats) {
        do {
            let stats = try await client.stats(days: nil)
            guard !Task.isCancelled else { return nil }
            return .topic(.statsLoaded(stats))
        } catch {
            // 静默：没有统计就只是没有统计。把 `.failed` 写在脸上才是过度反应。
            return nil
        }
    }
}
