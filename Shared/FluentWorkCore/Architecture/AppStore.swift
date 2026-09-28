import FactoryKit
import FluentWorkFeatureFlags
import TGReduxKit

public typealias AppStore = Store<AppState, AppAction>

public enum AppStoreFactory {
    /// 用**显式**给的容器造 store。
    ///
    /// container 是必传的，不给默认值 —— 这是有意的（F4）。默认值那个形状
    /// （`container: Container? = nil` + `?? Container.shared`）不会失败：忘了传
    /// 不报错、不崩，只是静默用上进程单例。于是「测试里注册了假实现却没生效」
    /// 与「生产里拿到了被测试污染的容器」**都表现为一个绿测试**。
    /// 改成必传以后，忘了传就是编译错。
    @MainActor
    public static func make(
        container: Container,
        initialState: AppState = .initial
    ) -> Store<AppState, AppAction> {
        Store(
            initialState: initialState,
            reducer: appReducer,
            middlewares: makeAppMiddlewares(container: container)
        )
    }

    /// 生产的组合根入口：拿共享容器造 store。
    ///
    /// **这是全仓唯一允许触到 `Container.shared` 的地方**（见
    /// `DependencyInjectionGuardTests` 的白名单）：显式地把「用全局容器」这件事
    /// 写在一个有名字的入口里，而不是撒在每个工厂的默认值上。
    /// 调用点只有 App 入口与 SwiftUI 预览。
    @MainActor
    public static func makeShared(initialState: AppState = .initial) -> AppStore {
        // 写全 `Container.shared` 而不是 `.shared`：白名单是靠文本审计的，
        // 简写会让这个「唯一入口」从 grep 里消失（这条正是被守卫逼出来的）。
        make(container: Container.shared, initialState: initialState)
    }
}

public extension Store where State == AppState, Action == AppAction {
    func featureFlagsScope() -> ScopedStore<FeatureFlagsState, FeatureFlagsAction> {
        scope(state: \.featureFlags, action: AppAction.featureFlags)
    }

    func speakingRoomScope() -> ScopedStore<SpeakingRoomState, SpeakingRoomAction> {
        scope(state: \.speakingRoom, action: AppAction.speakingRoom)
    }

    func workspaceScope() -> ScopedStore<WorkspaceState, WorkspaceAction> {
        scope(state: \.workspace, action: AppAction.workspace)
    }
}
