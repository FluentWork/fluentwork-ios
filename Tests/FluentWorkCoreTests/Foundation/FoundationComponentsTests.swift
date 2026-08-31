import Foundation
import FluentWorkDiagnostics
import FluentWorkFeatureFlags
import FluentWorkNetworking
import FluentWorkUI
import Testing
import TGReduxKitTesting
@testable import FluentWorkCore

@available(iOS 17, macOS 14, *)
@Test func audioSpeechActivityTrackerEmitsSpeechStartAndEnd() {
    var tracker = AudioSpeechActivityTracker()
    let clock = ContinuousClock()
    let start = clock.now

    #expect(tracker.register(energy: 0.02, at: start) == .speechStarted)
    #expect(tracker.register(energy: 0.02, at: start + .milliseconds(50)) == nil)
    #expect(tracker.register(energy: 0.0, at: start + .milliseconds(200)) == nil)
    #expect(tracker.register(energy: 0.0, at: start + .milliseconds(400)) == .speechEnded)
}

@available(iOS 17, macOS 14, *)
@Test func audioSpeechActivityTrackerResetOnlyEmitsWhenActive() {
    var tracker = AudioSpeechActivityTracker()
    let now = ContinuousClock().now

    #expect(tracker.reset() == nil)
    _ = tracker.register(energy: 0.02, at: now)
    #expect(tracker.reset() == .speechEnded)
    #expect(tracker.reset() == nil)
}

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

@Test func capturingLoggerSupportsConcurrentWrites() async {
    let logger = CapturingLogger()

    await withTaskGroup(of: Void.self) { group in
        for index in 0..<64 {
            group.addTask {
                logger.info("entry-\(index)", domain: .session)
            }
        }
    }

    #expect(logger.entries.count == 64)
}

@Test func capturingTrackerSupportsConcurrentWrites() async {
    let tracker = CapturingTracker()

    await withTaskGroup(of: Void.self) { group in
        for index in 0..<64 {
            group.addTask {
                tracker.track(event: "event-\(index)", properties: ["idx": "\(index)"])
            }
        }
    }

    #expect(tracker.events.count == 64)
}

@Test func inMemorySecureStorageSupportsConcurrentWrites() async throws {
    let storage = InMemorySecureStorage()

    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<64 {
            group.addTask {
                try storage.write(Data("value-\(index)".utf8), key: "key-\(index)")
            }
        }
        try await group.waitForAll()
    }

    for index in 0..<64 {
        #expect(try storage.read(key: "key-\(index)") == Data("value-\(index)".utf8))
    }
}

@Test func stubNetworkMonitorBroadcastsUpdatesToAllSubscribers() async {
    let monitor = StubNetworkMonitor(snapshot: .disconnected)
    let streamA = monitor.connectivityUpdates()
    let streamB = monitor.connectivityUpdates()

    let consumerA = Task { () async -> [NetworkPathSnapshot] in
        var iterator = streamA.makeAsyncIterator()
        var snapshots: [NetworkPathSnapshot] = []
        if let first = await iterator.next() {
            snapshots.append(first)
        }
        if let second = await iterator.next() {
            snapshots.append(second)
        }
        return snapshots
    }
    let consumerB = Task { () async -> [NetworkPathSnapshot] in
        var iterator = streamB.makeAsyncIterator()
        var snapshots: [NetworkPathSnapshot] = []
        if let first = await iterator.next() {
            snapshots.append(first)
        }
        if let second = await iterator.next() {
            snapshots.append(second)
        }
        return snapshots
    }

    let updated = NetworkPathSnapshot(isConnected: true, isExpensive: true, isConstrained: false)
    monitor.emit(updated)

    #expect(await consumerA.value == [.disconnected, updated])
    #expect(await consumerB.value == [.disconnected, updated])
    #expect(monitor.currentSnapshot() == updated)
}

@Test func stubNetworkMonitorRemovesTerminatedSubscriber() async {
    let monitor = StubNetworkMonitor(snapshot: .connected)
    do {
        let stream = monitor.connectivityUpdates()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(monitor.subscriberCountForTesting() == 1)
    }

    try? await Task.sleep(nanoseconds: 20_000_000)

    #expect(monitor.subscriberCountForTesting() == 0)
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
