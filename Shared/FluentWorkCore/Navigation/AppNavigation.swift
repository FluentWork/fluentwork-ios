import Foundation
import TGNavigationStack
import TGReduxKit

/// Bottom tabs: 工作台｜闪测｜语料库
public enum AppTab: String, CaseIterable, Codable, Hashable, Sendable {
    case workbench
    case flashTest
    case corpus
}

public enum AppRoute: TGRoute, Codable {
    case speakingRoom(sessionID: String?)
    case review(sessionID: String?)
    case dailyRead(sessionID: String?)

    /// Stable path shared with `FeaturePluginDescriptor.entryRoute`.
    public var entryRoute: String {
        switch self {
        case .speakingRoom:
            return "/speaking-room"
        case .review:
            return "/review"
        case .dailyRead:
            return "/daily-read"
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
        default:
            return nil
        }
    }

    /// Default workbench navigation semantics for user-facing module entry.
    /// Conversational surfaces stay full-screen; content reading stays in-stack.
    public var defaultWorkbenchNavigationAction: AppNavigationAction {
        switch self {
        case .speakingRoom, .review:
            return .workbench(.present(self, style: .fullScreenCover))
        case .dailyRead:
            return .workbench(.push(self))
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
