import Foundation
import TGNavigationStack
import TGReduxKit

/// Bottom tabs: **工作台｜闪测｜语料库**（三个）。
///
/// 这处分歧一直挂在代码里：稿子 §03 写「底部导航固定 3 项」，而实现里曾有第 4 个
/// `settings` —— 注释与 `问题总清单-PRD模块轴` 都记着它「已知且尚未拍板」。
/// **2026-10-01 按稿子拍板：三个 tab**，设置改成**从工作台推入的一页**
/// （稿子 屏 12 的顶栏就是「← 返回工作台 ＋ 设置」，而它的 tab bar 只有
/// 工作台 `i-home` / 闪测 `i-drill` / 语料库 `i-library` 三项）。
///
/// 设置不再是一等 tab 之后，它「刻意不受 flag 门禁」那条理由依然成立 ——
/// 只是现在由**推入这条路由**来保证（见 `AppRoute.settings`）。
public enum AppTab: String, CaseIterable, Codable, Hashable, Sendable {
    case workbench
    case flashTest
    case corpus
}

public enum AppRoute: TGRoute, Codable {
    case speakingRoom(sessionID: String?)
    case review(sessionID: String?)
    case dailyRead(sessionID: String?)
    /// The conversation list. Takes no `sessionID` — it is the thing that
    /// hands one out.
    case sessionHistory
    /// One past session, pushed from the list. Read-only.
    case sessionDetail(sessionID: String)

    /// 闪测（E1–E5）。
    ///
    /// 这里**不带 `sessionID`**：闪测读的是语料块，不是某一场会话。给它一个永远为 `nil`
    /// 的参数只会让「这个参数在什么情况下有值」变成一个没有答案的问题。
    case drill

    /// 话题建议页（H1–H3）。
    ///
    /// 同样不带 `sessionID`，理由同上。
    case topicCards

    /// 设置（屏 12）。
    ///
    /// **它是推入页，不是 tab**（2026-10-01 按稿子拍板）。稿子 屏 12 的顶栏是
    /// 「← 返回工作台 ＋ 设置」，而 tab bar 只有三项 —— 所以这一屏属于工作台那条栈。
    ///
    /// 它**不是** `FeaturePluginDescriptor`（也从来不是）：插件按各自的开关过滤，
    /// 而一个被开关挡在门外的设置页，只有已经打开过那个开关的人才进得去 ——
    /// 打开开关恰恰是它存在的理由。推入路由同样不受开关门禁。
    case settings

    /// 创建练习（屏 11）。
    ///
    /// 它**不是一个页面**，是底部弹层（稿子 §03：创建练习是「底部弹层，非全屏」）——
    /// 但它仍然是一条 `AppRoute`，因为「打开创建练习」是导航语义：
    /// 谁都能从自己的位置请求它，而不必各自去改一份「弹层开着没有」的布尔。
    /// 呈现样式在 `defaultWorkbenchNavigationAction` 上写明（`.sheet`）。
    case createPractice

    /// Stable path shared with `FeaturePluginDescriptor.entryRoute`.
    public var entryRoute: String {
        switch self {
        case .speakingRoom:
            return "/speaking-room"
        case .review:
            return "/review"
        case .dailyRead:
            return "/daily-read"
        case .sessionHistory:
            return "/sessions"
        case .sessionDetail(let sessionID):
            return "/sessions/\(sessionID)"
        case .drill:
            return "/drill"
        case .topicCards:
            return "/topic-cards"
        case .createPractice:
            return "/practice/new"
        case .settings:
            return "/settings"
        }
    }

    /// Maps plugin catalog paths into typed navigation routes.
    public init?(entryRoute: String, sessionID: String? = nil) {
        switch entryRoute {
        case "/speaking-room":
            self = .speakingRoom(sessionID: sessionID)
        case "/review":
            self = .review(sessionID: sessionID)
        case "/daily-read":
            self = .dailyRead(sessionID: sessionID)
        case "/sessions":
            self = .sessionHistory
        case "/drill":
            // `sessionID` 被刻意丢掉，和 `/sessions` 同理：闪测没有「继续某一场」这个语义，
            // 把参数收下来再丢掉，会让调用方以为它有用。
            self = .drill
        case "/topic-cards":
            self = .topicCards
        case "/settings":
            self = .settings
        case "/practice/new":
            self = .createPractice
        // Note what is *not* here: `/sessions/<id>`. That path exists on the
        // server, but on this side the detail is only ever reached by tapping a
        // row, which builds the route from the id it already has. Parsing it
        // back out of a string would add a second way to construct the same
        // route and a way to get it wrong.
        default:
            return nil
        }
    }

    /// Default workbench navigation semantics for user-facing module entry.
    ///
    /// Three behaviours, and the third is the one worth reading twice:
    ///
    /// - conversational surfaces (`speakingRoom` / `review`) stay full-screen;
    /// - content pages (`dailyRead` / `sessionHistory` / `sessionDetail` /
    ///   `topicCards`) stay in the stack;
    /// - **`drill` does not open a page at all** — it switches the bottom tab.
    ///
    /// That last one is not an inconsistency, it is the design: 09-26 稿 §03 puts
    /// 闪测 in **Tab 2** and audits the path as「底部 Tab → 直接开始」= 1 click. If a workbench
    /// tap pushed the same screen as a page, the screen would have two entry paths and therefore
    /// two behaviours (a pushed page vs. a tab root) — exactly the shape `HostRootView` refuses
    /// for `sessionDetail`'s「继续练习」. So the module entry points at the tab it lives in.
    public var defaultWorkbenchNavigationAction: AppNavigationAction {
        switch self {
        case .speakingRoom, .review:
            return .workbench(.present(self, style: .fullScreenCover))
        case .dailyRead, .sessionHistory, .sessionDetail, .topicCards, .settings:
            return .workbench(.push(self))
        case .createPractice:
            // 弹层（稿子 §03）。`.sheet` 也是 `present` 的默认值，写出来是因为
            // 这一行的**全部内容**就是「它不是全屏页」——省略它会把唯一的决定藏起来。
            return .workbench(.present(self, style: .sheet))
        case .drill:
            return .selectTab(.flashTest)
        }
    }

    public static func workbenchNavigationAction(
        entryRoute: String,
        sessionID: String? = nil
    ) -> AppNavigationAction? {
        guard let route = AppRoute(entryRoute: entryRoute, sessionID: sessionID) else {
            return nil
        }
        return route.defaultWorkbenchNavigationAction
    }
}

public struct AppNavigationState: Equatable, Sendable, State {
    public var selectedTab: AppTab
    public var workbench: NavigationState<AppRoute>
    public var flashTest: NavigationState<AppRoute>
    public var corpus: NavigationState<AppRoute>

    public init(
        selectedTab: AppTab = .workbench,
        workbench: NavigationState<AppRoute> = NavigationState(),
        flashTest: NavigationState<AppRoute> = NavigationState(),
        corpus: NavigationState<AppRoute> = NavigationState()
    ) {
        self.selectedTab = selectedTab
        self.workbench = workbench
        self.flashTest = flashTest
        self.corpus = corpus
    }

    public func stack(for tab: AppTab) -> NavigationState<AppRoute> {
        switch tab {
        case .workbench: return workbench
        case .flashTest: return flashTest
        case .corpus: return corpus
        }
    }
}

public enum AppNavigationAction: Equatable, Sendable, Action {
    case selectTab(AppTab)
    case workbench(NavigationAction<AppRoute>)
    case flashTest(NavigationAction<AppRoute>)
    case corpus(NavigationAction<AppRoute>)
}

public let appNavigationReducer: Reducer<AppNavigationState, AppNavigationAction> = { state, action in
    switch action {
    case let .selectTab(tab):
        state.selectedTab = tab

    case let .workbench(navAction):
        navigationReducer(state: &state.workbench, action: navAction)

    case let .flashTest(navAction):
        navigationReducer(state: &state.flashTest, action: navAction)

    case let .corpus(navAction):
        navigationReducer(state: &state.corpus, action: navAction)
    }
}
