import FluentWorkFeatureFlags
import FluentWorkPluginSupport
import Foundation
import TGReduxKit

public let appReducer: Reducer<AppState, AppAction> = combineReducers(
  pullback(
    featureFlagsReducer,
    state: \.featureFlags,
    action: AppAction.featureFlags,
    extract: {
      guard case .featureFlags(let action) = $0 else { return nil }
      return action
    }
  ),
  pullback(
    authReducer,
    state: \.auth,
    action: AppAction.auth,
    extract: {
      guard case .auth(let action) = $0 else { return nil }
      return action
    }
  ),
  pullback(
    speakingRoomReducer,
    state: \.speakingRoom,
    action: AppAction.speakingRoom,
    extract: {
      guard case .speakingRoom(let action) = $0 else { return nil }
      return action
    }
  ),
  pullback(
    reviewReducer,
    state: \.review,
    action: AppAction.review,
    extract: {
      guard case .review(let action) = $0 else { return nil }
      return action
    }
  ),
  pullback(
    corpusReducer,
    state: \.corpus,
    action: AppAction.corpus,
    extract: {
      guard case .corpus(let action) = $0 else { return nil }
      return action
    }
  ),
  pullback(
    dailyReadReducer,
    state: \.dailyRead,
    action: AppAction.dailyRead,
    extract: {
      guard case .dailyRead(let action) = $0 else { return nil }
      return action
    }
  ),
  pullback(
    workspaceReducer,
    state: \.workspace,
    action: AppAction.workspace,
    extract: {
      guard case .workspace(let action) = $0 else { return nil }
      return action
    }
  ),
  pullback(
    badgeFeedbackReducer,
    state: \.badgeFeedback,
    action: AppAction.badgeFeedback,
    extract: {
      guard case .badgeFeedback(let action) = $0 else { return nil }
      return action
    }
  ),
  pullback(
    networkConnectivityReducer,
    state: \.network,
    action: AppAction.network,
    extract: {
      guard case .network(let action) = $0 else { return nil }
      return action
    }
  ),
  pullback(
    appNavigationReducer,
    state: \.navigation,
    action: AppAction.navigation,
    extract: {
      guard case .navigation(let action) = $0 else { return nil }
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

  case .lifecycle(.bootstrapSucceeded(let snapshot)):
    state.bootstrapStatus = .ready
    state.workspace.isBootstrapComplete = true
    state.workspace.activeSurface = snapshot.preferredSurface
    state.featureFlags.snapshot = snapshot.featureFlags
    state.featureFlags.isRemoteLoaded = true
    applyFeatureFlagProjection(to: &state)

  case .lifecycle(.bootstrapFailed(let message)):
    state.bootstrapStatus = .failed
    state.lastErrorMessage = message

  case .featureFlags(.applyRemoteSnapshot(let snapshot)):
    state.featureFlags.snapshot = snapshot
    state.featureFlags.isRemoteLoaded = true
    applyFeatureFlagProjection(to: &state)

  case .featureFlags(.setLocalOverride), .featureFlags(.clearLocalOverrides):
    applyFeatureFlagProjection(to: &state)

  case .speakingRoom(.badgeHit(let badge, let phraseBlockID, let tier, let turnID)):
    state.workspace.highlightedBadge = badge
    state.workspace.badgeFeedCount += 1
    // Mirror into the badge display layer (`I11`). Timestamp source is
    // always "now" — display lifecycle is short (<= `visibleWindowSeconds`)
    // and tolerates coarse wall-clock granularity. Tests for the display
    // reducer exercise the pure reducer directly with fixed dates; the
    // cross-cutting mirror only needs to keep the workspace projection in
    // step with what the UI actually shows.
    //
    // Tier falls back to `.unknown` when the speaking-room layer doesn't
    // have one (e.g. a host debug button). The cross-cutting mirror is the
    // only place that knows about transport `phraseBlockID`; pass it
    // through to keep iOS-side dedupe aligned with the backend.
    state.badgeFeedback.ingest(
      badge: badge,
      turnID: turnID,
      tier: tier ?? .unknown,
      at: Date(),
      phraseBlockID: phraseBlockID
    )

  case .auth(.signedInAsGuest), .auth(.mergedIntoRegistered):
    state.corpus = CorpusState()

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
