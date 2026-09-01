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
        FeaturePluginDescriptor(
            feature: .dailyRead,
            moduleName: "DailyRead",
            entryRoute: "/daily-read"
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

    store.send(.speakingRoom(.badgeHit(badge: "表达自然")))

    // Speaking-room + workspace mirrors are unchanged by `I11`.
    #expect(store.state.speakingRoom.lastBadge == "表达自然")
    #expect(store.state.speakingRoom.badgeHits == 1)
    #expect(store.state.workspace.highlightedBadge == "表达自然")
    #expect(store.state.workspace.badgeFeedCount == 1)
    // `I11`: badge display layer also receives the hit (UUID makes
    // struct-level equality unstable, compare by field).
    #expect(store.state.badgeFeedback.entries.count == 1)
    #expect(store.state.badgeFeedback.entries.first?.badge == "表达自然")
    #expect(store.state.badgeFeedback.entries.first?.tier == .unknown)
    #expect(store.state.badgeFeedback.entries.first?.turnID == nil)
    #expect(store.state.badgeFeedback.entries.first?.phraseBlockID == nil)
}

@Test func speakingRoomBadgeHitWithEnrichmentMirrorsAllFields() throws {
    let store = TestStore(initialState: AppState.initial, reducer: appReducer)

    store.send(
        .speakingRoom(.badgeHit(
            badge: "节奏稳定",
            phraseBlockID: "block-42",
            tier: .nextTurnConfirm,
            turnID: "turn-1"
        ))
    )

    #expect(store.state.speakingRoom.lastBadge == "节奏稳定")
    #expect(store.state.speakingRoom.badgeHits == 1)
    #expect(store.state.workspace.highlightedBadge == "节奏稳定")
    #expect(store.state.workspace.badgeFeedCount == 1)
    #expect(store.state.badgeFeedback.entries.count == 1)
    #expect(store.state.badgeFeedback.entries.first?.badge == "节奏稳定")
    #expect(store.state.badgeFeedback.entries.first?.phraseBlockID == "block-42")
    #expect(store.state.badgeFeedback.entries.first?.turnID == "turn-1")
    #expect(store.state.badgeFeedback.entries.first?.tier == .nextTurnConfirm)
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
        FeaturePluginDescriptor(
            feature: .dailyRead,
            moduleName: "DailyRead",
            entryRoute: "/daily-read"
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
    let store = TGReduxKitTesting.TestStore(initialState: AppState.initial, reducer: appReducer)

    var expected = AppState.initial
    expected.bootstrapStatus = .loading
    store.send(AppAction.lifecycle(.appLaunched))
    try store.assert(equals: expected)
}
