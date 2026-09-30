import Foundation
import TGNavigationStack
import TGReduxKit

/// Bottom tabs: 工作台｜闪测｜语料库｜设置。
///
/// **四个，而 09-26 稿 §03 写的是「底部导航固定 3 项」。** 这处分歧是**已知且尚未拍板**的
/// （meta `问题总清单-PRD模块轴` 的「底部 Tab 数」一行记着它）。这一行只把代码里的事实写对 ——
/// 它此前写着「工作台｜闪测｜语料库」，那是**撒谎**，而撒谎的注释比没有注释更难查。
public enum AppTab: String, CaseIterable, Codable, Hashable, Sendable {
    case workbench
    case flashTest
    case corpus
    /// Settings.
    ///
    /// Deliberately **not** a `FeaturePluginDescriptor`, unlike every other
    /// surface: plugins are filtered by their own feature flag
    /// (`FeaturePluginRegistry.enabledPlugins(for:)`), so a flag-gated settings
    /// page could only be reached by someone who had already turned its flag
    /// on — and turning flags on is the one thing it exists to do.
    case settings
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
        case .dailyRead, .sessionHistory, .sessionDetail, .topicCards:
            return .workbench(.push(self))
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
    public var settings: NavigationState<AppRoute>

    public init(
        selectedTab: AppTab = .workbench,
        workbench: NavigationState<AppRoute> = NavigationState(),
        flashTest: NavigationState<AppRoute> = NavigationState(),
        corpus: NavigationState<AppRoute> = NavigationState(),
        settings: NavigationState<AppRoute> = NavigationState()
    ) {
        self.selectedTab = selectedTab
        self.workbench = workbench
        self.flashTest = flashTest
        self.corpus = corpus
        self.settings = settings
    }

    public func stack(for tab: AppTab) -> NavigationState<AppRoute> {
        switch tab {
        case .workbench: return workbench
        case .flashTest: return flashTest
        case .corpus: return corpus
        case .settings: return settings
        }
    }
}

public enum AppNavigationAction: Equatable, Sendable, Action {
    case selectTab(AppTab)
    case workbench(NavigationAction<AppRoute>)
    case flashTest(NavigationAction<AppRoute>)
    case corpus(NavigationAction<AppRoute>)
    case settings(NavigationAction<AppRoute>)
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

    case let .settings(navAction):
        navigationReducer(state: &state.settings, action: navAction)
    }
}
