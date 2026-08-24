import FactoryKit
import FluentWorkFeatureFlags
import TGReduxKit

public enum AppStoreFactory {
    @MainActor
    public static func make(
        container: Container? = nil,
        initialState: AppState = .initial
    ) -> Store<AppState, AppAction> {
        let resolvedContainer = container ?? Container.shared
        return Store(
            initialState: initialState,
            reducer: appReducer,
            middlewares: makeAppMiddlewares(container: resolvedContainer)
        )
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
