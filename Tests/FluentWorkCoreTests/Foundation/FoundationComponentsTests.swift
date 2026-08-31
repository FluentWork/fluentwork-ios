import Foundation
import FluentWorkDiagnostics
import FluentWorkFeatureFlags
import FluentWorkNetworking
import FluentWorkUI
import Testing
import TGReduxKitTesting
@testable import FluentWorkCore

@Test func capturingLoggerRecordsEntriesByDomain() {
    let logger = CapturingLogger()
    logger.info("hello", domain: .api)
    logger.error("boom", domain: .transport)

    #expect(logger.entries.count == 2)
    #expect(logger.entries[0].domain == .api)
    #expect(logger.entries[1].level == .error)
}

@Test func capturingTrackerRecordsEvents() {
    let tracker = CapturingTracker()
    tracker.track(event: "session_start", properties: ["phase": "connecting"])
    #expect(tracker.events == [
        .init(name: "session_start", properties: ["phase": "connecting"]),
    ])
}

@Test func inMemorySecureStorageRoundTripsData() throws {
    let storage = InMemorySecureStorage()
    let payload = Data("ticket".utf8)
    try storage.write(payload, key: "session.ticket")
    #expect(try storage.read(key: "session.ticket") == payload)
    try storage.delete(key: "session.ticket")
    #expect(try storage.read(key: "session.ticket") == nil)
}

@Test func inMemoryCorpusCacheStoreRoundTripsSnapshot() async throws {
    let store = InMemoryCorpusCacheStore()
    let snapshot = CachedCorpusSnapshot(
        items: [
            PhraseBlock(
                id: "b-1",
                intentZH: "表达感谢",
                expressionEN: "Thank you.",
                anchorUserSaid: "thanks",
                sceneTag: "work",
                functionTag: "gratitude",
                state: "new",
                successStreak: 0,
                nextDueAt: "2026-09-01T10:00:00Z",
                easeFactor: 2.5,
                realUseCount: 0,
                isFavorite: false,
                pinnedAt: nil,
                sourceSessionID: "session-1",
                createdAt: "2026-08-31T09:00:00Z",
                updatedAt: "2026-08-31T10:00:00Z"
            ),
        ],
        nextCursor: "cursor-1"
    )

    try await store.saveSnapshot(snapshot, scope: "guest-1")
    #expect(try await store.loadSnapshot(scope: "guest-1") == snapshot)
    try await store.clearSnapshot(scope: "guest-1")
    #expect(try await store.loadSnapshot(scope: "guest-1") == nil)
}

@Test func inMemoryCorpusOutboxStoreRoundTripsItems() async throws {
    let store = InMemoryCorpusOutboxStore()
    let items = [
        CorpusOutboxItem(
            id: "op-1",
            blockID: "b-1",
            operation: .favorite,
            payload: .init(isFavorite: true, pinned: true),
            retryCount: 0,
            createdAt: "2026-08-31T10:00:00Z"
        ),
    ]

    try await store.saveItems(items, scope: "guest-1")
    #expect(try await store.loadItems(scope: "guest-1") == items)
    try await store.clearItems(scope: "guest-1")
    #expect(try await store.loadItems(scope: "guest-1").isEmpty)
}

@Test func inMemoryCorpusSyncMetadataStoreRoundTripsMetadata() async throws {
    let store = InMemoryCorpusSyncMetadataStore()
    let metadata = CorpusSyncMetadata(listCursor: "cursor-1", syncCursor: "2026-08-31T10:00:00Z")

    try await store.save(metadata, scope: "user-42")
    #expect(try await store.load(scope: "user-42") == metadata)
    try await store.clear(scope: "user-42")
    #expect(try await store.load(scope: "user-42") == nil)
}

@Test func fixedClockAndIDGeneratorAreDeterministic() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let uuid = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!
    let clock = FixedClock(date: date)
    let ids = FixedIDGenerator(value: uuid)

    #expect(clock.now() == date)
    #expect(ids.uuid() == uuid)
}

@Test func appEnvironmentLocalPointsAtLoopback() {
    #expect(AppEnvironment.local.apiBaseURL.host == "127.0.0.1")
    #expect(AppEnvironment.local.wssBaseURL.scheme == "ws")
}

@Test func designTokensExposeDarkDefaultPalette() {
    #expect(DesignTokens.Color.backgroundPrimary.hasPrefix("#"))
    #expect(DesignTokens.Typography.titlePointSize == 20)
    #expect(DesignTokens.Motion.standardSeconds == 0.25)
}

@Test func networkConnectivityReducerAppliesSnapshot() throws {
    let store = TestStore(
        initialState: NetworkConnectivityState(),
        reducer: networkConnectivityReducer
    )

    var expected = NetworkConnectivityState()
    expected.isConnected = false
    expected.isExpensive = true
    expected.isConstrained = true

    store.send(
        .connectivityChanged(
            NetworkPathSnapshot(isConnected: false, isExpensive: true, isConstrained: true)
        )
    )
    try store.assert(equals: expected)
}

@Test func navigationReducerPresentsSpeakingRoomFullScreen() throws {
    let store = TestStore(
        initialState: AppNavigationState(),
        reducer: appNavigationReducer
    )

    var expected = AppNavigationState()
    expected.workbench.presentedRoute = .speakingRoom(sessionID: "s1")
    expected.workbench.presentationStyle = .fullScreenCover

    store.send(
        .workbench(.present(.speakingRoom(sessionID: "s1"), style: .fullScreenCover))
    )
    try store.assert(equals: expected)
}

@Test func navigationSelectTabUpdatesSelectedTab() throws {
    let store = TestStore(
        initialState: AppNavigationState(),
        reducer: appNavigationReducer
    )

    var expected = AppNavigationState()
    expected.selectedTab = .corpus
    store.send(.selectTab(.corpus))
    try store.assert(equals: expected)
}

@Test func apiErrorUserFacingMessageIsPlaceholder() {
    let error = APIError.backend(code: "auth_expired", message: "expired")
    #expect(error.userFacingMessage == nil)
}

@Test func featureFlagSnapshotMapperMapsResolverOutput() async {
    let resolver = FeatureFlagResolverFactory.makeFirstWaveResolver()
    _ = await resolver.refresh()
    let remote = resolver.snapshot(for: AppFeatureFlag.allCases)
    let domain = FeatureFlagSnapshotMapper.map(remote)

    #expect(domain.isEnabled(.speakingRoom))
    #expect(domain.isEnabled(.workspaceReview))
    #expect(domain.isEnabled(.degradedTextMode))
    #expect(!domain.isEnabled(.dailyRead))
}
