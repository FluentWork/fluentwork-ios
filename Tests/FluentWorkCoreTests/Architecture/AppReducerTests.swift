import FluentWorkFeatureFlags
import FluentWorkPluginSupport
import Testing
import TGReduxKit
@testable import FluentWorkCore

@MainActor
@Test func bootstrapSuccessUpdatesGlobalStateAndFeatureScopes() throws {
    let store = TestStore(initialState: .initial, reducer: appReducer)
    let snapshot = BootstrapSnapshot(
        featureFlags: .firstWave,
        preferredSurface: .speakingRoom
    )

    var expected = AppState.initial
    expected.bootstrapStatus = .loading
    try store.send(.lifecycle(.bootstrapStarted), expect: expected)

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
    try store.send(.lifecycle(.bootstrapSucceeded(snapshot)), expect: expected)
}

@MainActor
@Test func speakingRoomBadgeHitFeedsWorkspaceProjection() throws {
    let store = TestStore(initialState: .initial, reducer: appReducer)

    var expected = AppState.initial
    expected.speakingRoom.lastBadge = "表达自然"
    expected.speakingRoom.badgeHits = 1
    expected.workspace.highlightedBadge = "表达自然"
    expected.workspace.badgeFeedCount = 1

    try store.send(.speakingRoom(.badgeHit("表达自然")), expect: expected)
}

@MainActor
@Test func guestIdentityCanPromoteToRegisteredWithoutLosingFlow() throws {
    let store = TestStore(initialState: .initial, reducer: appReducer)

    var expected = AppState.initial
    expected.auth.mode = .guest
    expected.auth.currentUserID = "guest-1"
    expected.auth.pendingMergeDeviceID = "device-1"
    try store.send(
        .auth(.signedInAsGuest(userID: "guest-1", deviceID: "device-1")),
        expect: expected
    )

    expected.auth.mode = .registered
    expected.auth.currentUserID = "user-42"
    expected.auth.pendingMergeDeviceID = nil
    try store.send(
        .auth(.mergedIntoRegistered(userID: "user-42", deviceID: "device-1")),
        expect: expected
    )
}

@MainActor
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
    try store.send(
        .featureFlags(.setLocalOverride(flag: .speakingRoom, isEnabled: false)),
        expect: expected
    )
}

@MainActor
@Test func workspaceCanReceivePluginizedEntryModules() throws {
    let store = TestStore(initialState: .initial, reducer: appReducer)
    let modules = [
        FeaturePluginDescriptor(
            feature: .speakingRoom,
            moduleName: "SpeakingRoom",
            entryRoute: "/speaking-room"
        ),
    ]

    var expected = AppState.initial
    expected.workspace.availableModules = modules
    try store.send(.workspace(.setAvailableModules(modules)), expect: expected)
}

@MainActor
@Test func sessionStartResetsBadgeStateForNewRun() throws {
    let initial = AppState(
        speakingRoom: SpeakingRoomState(
            phase: .processing,
            liveTranscript: "旧转写",
            isBootstrapReady: true,
            lastBadge: "表达自然",
            badgeHits: 2,
            failureReason: "旧错误"
        )
    )
    let store = TestStore(initialState: initial, reducer: appReducer)

    var expected = initial
    expected.speakingRoom.phase = .connecting
    expected.speakingRoom.liveTranscript = ""
    expected.speakingRoom.lastBadge = nil
    expected.speakingRoom.badgeHits = 0
    expected.speakingRoom.failureReason = nil

    try store.send(.speakingRoom(.sessionStartTapped), expect: expected)
}

@MainActor
@Test func failedSpeakingRoomIgnoresLateSocketEvents() throws {
    let initial = AppState(
        speakingRoom: SpeakingRoomState(
            phase: .failed,
            isBootstrapReady: true,
            failureReason: "网络错误"
        )
    )
    let store = TestStore(initialState: initial, reducer: appReducer)

    try store.send(.speakingRoom(.socketReady), expect: initial)
    try store.send(.speakingRoom(.networkDowngraded), expect: initial)
}
