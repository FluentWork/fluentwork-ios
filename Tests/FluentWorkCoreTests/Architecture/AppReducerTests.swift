import FluentWorkFeatureFlags
import FluentWorkPluginSupport
import Testing
import TGReduxKitTesting
@testable import FluentWorkCore

@Test func bootstrapSuccessUpdatesGlobalStateAndFeatureScopes() throws {
    let store = TestStore(initialState: AppState.initial, reducer: appReducer)
    let snapshot = BootstrapSnapshot(
        featureFlags: .firstWave,
        preferredSurface: .speakingRoom
    )

    var expected = AppState.initial
    expected.bootstrapStatus = .loading
    store.send(.lifecycle(.bootstrapStarted))
    try store.assert(equals: expected)

    expected.bootstrapStatus = .ready
    expected.workspace.isBootstrapComplete = true
    expected.workspace.activeSurface = .speakingRoom
    expected.workspace.availableModules = [
        FeaturePluginDescriptor(
            feature: .speakingRoom,
            moduleName: "SpeakingRoom",
            entryRoute: "/speaking-room"
        ),
        FeaturePluginDescriptor(
            feature: .workspaceReview,
            moduleName: "Review",
            entryRoute: "/review"
        ),
    ]
    expected.featureFlags.snapshot = .firstWave
    expected.featureFlags.isRemoteLoaded = true
    expected.speakingRoom.isBootstrapReady = true
    store.send(.lifecycle(.bootstrapSucceeded(snapshot)))
    try store.assert(equals: expected)
}

@Test func speakingRoomBadgeHitFeedsWorkspaceProjection() throws {
    let store = TestStore(initialState: AppState.initial, reducer: appReducer)

    var expected = AppState.initial
    expected.speakingRoom.lastBadge = "表达自然"
    expected.speakingRoom.badgeHits = 1
    expected.workspace.highlightedBadge = "表达自然"
    expected.workspace.badgeFeedCount = 1

    store.send(.speakingRoom(.badgeHit("表达自然")))
    try store.assert(equals: expected)
}

@Test func guestIdentityCanPromoteToRegisteredWithoutLosingFlow() throws {
    let store = TestStore(initialState: AppState.initial, reducer: appReducer)

    var expected = AppState.initial
    expected.auth.mode = .guest
    expected.auth.currentUserID = "guest-1"
    expected.auth.pendingMergeDeviceID = "device-1"
    store.send(.auth(.signedInAsGuest(userID: "guest-1", deviceID: "device-1")))
    try store.assert(equals: expected)

    expected.auth.mode = .registered
    expected.auth.currentUserID = "user-42"
    expected.auth.pendingMergeDeviceID = nil
    store.send(.auth(.mergedIntoRegistered(userID: "user-42", deviceID: "device-1")))
    try store.assert(equals: expected)
}

@Test func featureFlagsCanDisableSpeakingRoomViaLocalOverride() throws {
    let initial = AppState(
        featureFlags: FeatureFlagsState(snapshot: .firstWave, isRemoteLoaded: true),
        speakingRoom: SpeakingRoomState(isBootstrapReady: true)
    )
    let store = TestStore(initialState: initial, reducer: appReducer)

    var expected = initial
    expected.featureFlags.localOverrides[.speakingRoom] = false
    expected.speakingRoom.isBootstrapReady = false
    expected.workspace.availableModules = [
        FeaturePluginDescriptor(
            feature: .workspaceReview,
            moduleName: "Review",
            entryRoute: "/review"
        ),
    ]
    store.send(.featureFlags(.setLocalOverride(flag: .speakingRoom, isEnabled: false)))
    try store.assert(equals: expected)
}

@Test func workspaceCanReceivePluginizedEntryModules() throws {
    let store = TestStore(initialState: AppState.initial, reducer: appReducer)
    let modules = [
        FeaturePluginDescriptor(
            feature: .speakingRoom,
            moduleName: "SpeakingRoom",
            entryRoute: "/speaking-room"
        ),
    ]

    var expected = AppState.initial
    expected.workspace.availableModules = modules
    store.send(.workspace(.setAvailableModules(modules)))
    try store.assert(equals: expected)
}

@Test func appLaunchedSetsBootstrapLoading() throws {
    let store = TestStore(initialState: AppState.initial, reducer: appReducer)

    var expected = AppState.initial
    expected.bootstrapStatus = .loading
    store.send(.lifecycle(.appLaunched))
    try store.assert(equals: expected)
}
