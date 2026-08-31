import FluentWorkFeatureFlags
import FluentWorkPluginSupport
import TGReduxKit

public let appReducer: Reducer<AppState, AppAction> = combineReducers(
    pullback(
        featureFlagsReducer,
        state: \.featureFlags,
        action: AppAction.featureFlags,
        extract: {
            guard case let .featureFlags(action) = $0 else { return nil }
            return action
        }
    ),
    pullback(
        authReducer,
        state: \.auth,
        action: AppAction.auth,
        extract: {
            guard case let .auth(action) = $0 else { return nil }
            return action
        }
    ),
    pullback(
        speakingRoomReducer,
        state: \.speakingRoom,
        action: AppAction.speakingRoom,
        extract: {
            guard case let .speakingRoom(action) = $0 else { return nil }
            return action
        }
    ),
    pullback(
        reviewReducer,
        state: \.review,
        action: AppAction.review,
        extract: {
            guard case let .review(action) = $0 else { return nil }
            return action
        }
    ),
    pullback(
        workspaceReducer,
        state: \.workspace,
        action: AppAction.workspace,
        extract: {
            guard case let .workspace(action) = $0 else { return nil }
            return action
        }
    ),
    pullback(
        networkConnectivityReducer,
        state: \.network,
        action: AppAction.network,
        extract: {
            guard case let .network(action) = $0 else { return nil }
            return action
        }
    ),
    pullback(
        appNavigationReducer,
        state: \.navigation,
        action: AppAction.navigation,
        extract: {
            guard case let .navigation(action) = $0 else { return nil }
            return action
        }
    ),
    appCrossCuttingReducer
)

public let appCrossCuttingReducer: Reducer<AppState, AppAction> = { state, action in
    switch action {
    case .lifecycle(.appLaunched):
        state.bootstrapStatus = .loading
        state.lastErrorMessage = nil

    case .lifecycle(.bootstrapStarted):
        state.bootstrapStatus = .loading
        state.lastErrorMessage = nil

    case let .lifecycle(.bootstrapSucceeded(snapshot)):
        state.bootstrapStatus = .ready
        state.workspace.isBootstrapComplete = true
        state.workspace.activeSurface = snapshot.preferredSurface
        state.featureFlags.snapshot = snapshot.featureFlags
        state.featureFlags.isRemoteLoaded = true
        applyFeatureFlagProjection(to: &state)

    case let .lifecycle(.bootstrapFailed(message)):
        state.bootstrapStatus = .failed
        state.lastErrorMessage = message

    case let .featureFlags(.applyRemoteSnapshot(snapshot)):
        state.featureFlags.snapshot = snapshot
        state.featureFlags.isRemoteLoaded = true
        applyFeatureFlagProjection(to: &state)

    case .featureFlags(.setLocalOverride), .featureFlags(.clearLocalOverrides):
        applyFeatureFlagProjection(to: &state)

    case let .speakingRoom(.badgeHit(badge)):
        state.workspace.highlightedBadge = badge
        state.workspace.badgeFeedCount += 1

    default:
        break
    }
}

private func applyFeatureFlagProjection(to state: inout AppState) {
    let effectiveSnapshot = state.featureFlags.effectiveSnapshot
    let pluginRegistry = StaticFeaturePluginRegistry()

    state.speakingRoom.isBootstrapReady = effectiveSnapshot.isEnabled(.speakingRoom)
    state.workspace.availableModules = pluginRegistry.enabledPlugins(for: effectiveSnapshot)
}
