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
    // Below silenceHold (1500ms default) — must NOT emit.
    #expect(tracker.register(energy: 0.0, at: start + .milliseconds(1400)) == nil)
    // At or beyond silenceHold — must emit speechEnded.
    #expect(tracker.register(energy: 0.0, at: start + .milliseconds(1600)) == .speechEnded)
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

@available(iOS 17, macOS 14, *)
@Test func audioSpeechActivityTrackerDiscardDoesNotEmitSpeechEnded() {
    var tracker = AudioSpeechActivityTracker()
    let now = ContinuousClock().now

    _ = tracker.register(energy: 0.02, at: now)
    tracker.discard()
    #expect(tracker.reset() == nil)
    #expect(tracker.register(energy: 0.02, at: now) == .speechStarted)
}

/// Tap-to-start: the tap opens the turn and a stable silence submits it, so a
/// turn costs one gesture. Energy must not open a turn on its own — that is
/// what turns the microphone on without the user asking for it.
@available(iOS 17, macOS 14, *)
@Test func audioSpeechActivityTrackerTapToStartIgnoresEnergyUntilTapped() {
    var tracker = AudioSpeechActivityTracker(autoStart: false)
    let clock = ContinuousClock()
    let start = clock.now

    // Speaking before the tap must not open a turn.
    #expect(tracker.register(energy: 0.02, at: start) == nil)
    #expect(!tracker.isSpeechActive)

    // The tap opens it.
    #expect(tracker.forceStart() == .speechStarted)

    // A stable silence after speech submits it — no second tap.
    #expect(tracker.register(energy: 0.02, at: start + .milliseconds(50)) == nil)
    #expect(tracker.register(energy: 0.0, at: start + .milliseconds(1400)) == nil)
    #expect(tracker.register(energy: 0.0, at: start + .milliseconds(1600)) == .speechEnded)
}

/// Tap-to-start must tolerate a speaker pausing to think. The 1.5s auto-VAD
/// hold cut learners off mid-sentence: a turn that should run 20s was being
/// submitted after 2s because the user paused to find a word.
@available(iOS 17, macOS 14, *)
@Test func audioSpeechActivityTrackerTapToStartToleratesAThinkingPause() {
    var tracker = AudioSpeechActivityTracker(
        silenceHold: AudioSpeechActivityTracker.tapToStartSilenceHold,
        autoStart: false
    )
    let clock = ContinuousClock()
    let start = clock.now

    #expect(tracker.forceStart() == .speechStarted)
    #expect(tracker.register(energy: 0.02, at: start) == nil)

    // The auto-VAD hold would already have submitted here.
    #expect(tracker.register(energy: 0.0, at: start + .milliseconds(1600)) == nil)
    #expect(tracker.register(energy: 0.0, at: start + .milliseconds(3000)) == nil)
    #expect(tracker.isSpeechActive)

    // Derived from the constant rather than written out: the assertion is
    // "a pause just short of the hold does not submit", which is what the mode
    // promises. A literal here only restates whatever the hold happens to be.
    let nearlySettled = AudioSpeechActivityTracker.tapToStartSilenceHold * 3 / 4
    #expect(tracker.register(energy: 0.0, at: start + nearlySettled) == nil)
    #expect(tracker.isSpeechActive)

    // Only a genuinely settled silence closes the turn.
    #expect(
        tracker.register(energy: 0.0, at: start + AudioSpeechActivityTracker.tapToStartSilenceHold)
            == .speechEnded
    )
}

/// The endpointing hold can only be argued about until the number that decides
/// it is measured: how long the room waited after the last sound before
/// submitting. This pins the measurement itself.
@available(iOS 17, macOS 14, *)
@Test func speechTrackerReportsTheSilenceThatClosedTheTurn() {
    // A short hold, so the numbers in the assertions are the shape of the
    // measurement and not a coincidence of the shipped 8s.
    var tracker = AudioSpeechActivityTracker(silenceHold: .milliseconds(200), autoStart: true)
    let clock = ContinuousClock()
    let start = clock.now

    _ = tracker.register(energy: 0.02, at: start) // turn opens
    _ = tracker.register(energy: 0.02, at: start + .milliseconds(600)) // last sound
    // A pause short of the hold must not close it — and must not record
    // anything, so a turn still in flight has no endpoint at all. It must also
    // not move the reference point: this is silence, not sound.
    _ = tracker.register(energy: 0.0, at: start + .milliseconds(700))
    #expect(tracker.lastEndpoint == nil, "a turn still in flight has no endpoint")

    // Closed at 900ms with the last sound at 600ms: the silence is 300ms while
    // the hold is 200ms. Deliberately not equal — if the two coincided, a bug
    // that recorded the *hold* instead of the measurement would pass.
    #expect(tracker.register(energy: 0.0, at: start + .milliseconds(900)) == .speechEnded)
    #expect(tracker.lastEndpoint?.reason == .silenceHold)
    #expect(
        tracker.lastEndpoint?.trailingSilence == .milliseconds(300),
        "measured from the last sound (600ms) — not from the turn's start, not from the last silent sample, and not the hold itself"
    )
}

/// A tap is the other way a turn ends, and it has no trailing silence to
/// report. `nil` rather than zero: zero would read as "stopped and finished
/// instantly", which is a real case and a different one — and telling them
/// apart is the entire point of the measurement.
@available(iOS 17, macOS 14, *)
@Test func speechTrackerReportsNoTrailingSilenceWhenTheUserTappedDone() {
    var tracker = AudioSpeechActivityTracker(autoStart: false)
    _ = tracker.forceStart()
    _ = tracker.forceEnd()

    #expect(tracker.lastEndpoint?.reason == .manual)
    #expect(tracker.lastEndpoint?.trailingSilence == nil)
}

/// The hold is a property of the mode, not a single global.
@available(iOS 17, macOS 14, *)
@Test func tapToStartSilenceHoldOutlastsAutoVADHold() {
    #expect(
        AudioSpeechActivityTracker.tapToStartSilenceHold
            > AudioSpeechActivityTracker.autoVADSilenceHold
    )
}

/// A tap followed by silence must not submit an empty turn: `lastSpeechAt`
/// stays nil until the user actually speaks, so the turn falls through to the
/// 60s recording abort instead of ending with nothing in it.
@available(iOS 17, macOS 14, *)
@Test func audioSpeechActivityTrackerTapThenSilenceDoesNotSubmitEmptyTurn() {
    var tracker = AudioSpeechActivityTracker(autoStart: false)
    let clock = ContinuousClock()
    let start = clock.now

    #expect(tracker.forceStart() == .speechStarted)
    #expect(tracker.register(energy: 0.0, at: start + .seconds(5)) == nil)
    #expect(tracker.register(energy: 0.0, at: start + .seconds(30)) == nil)
    #expect(tracker.isSpeechActive)
}

@Test func audioPlaybackGateDropsFramesAtAndBeforeInterruptWatermark() {
    var gate = AudioPlaybackGate()
    let first = WSAudioFrame(sequence: 10, opusPayload: Data([0x01]))
    let second = WSAudioFrame(sequence: 11, opusPayload: Data([0x02]))
    let stale = WSAudioFrame(sequence: 11, opusPayload: Data([0x03]))
    let fresh = WSAudioFrame(sequence: 12, opusPayload: Data([0x04]))

    let acceptedFirst = gate.shouldAccept(first)
    let acceptedSecond = gate.shouldAccept(second)
    #expect(gate.markInterrupted() == 11)
    let acceptedStale = gate.shouldAccept(stale)
    let acceptedFresh = gate.shouldAccept(fresh)

    #expect(acceptedFirst == .accept)
    #expect(acceptedSecond == .accept)
    // The verdict carries the watermark, not just "no". That number is the only
    // way the drop can be attributed to the interrupt that caused it once it
    // reaches a log — a bare `false` says a frame was lost and nothing about
    // which of the session's interrupts took it.
    #expect(acceptedStale == .droppedAtOrBelowInterruptWatermark(11))
    #expect(acceptedFresh == .accept)
}

@Test func audioPlaybackGateResetClearsInterruptWatermark() {
    var gate = AudioPlaybackGate()
    let acceptedBeforeInterrupt = gate.shouldAccept(
        WSAudioFrame(sequence: 4, opusPayload: Data([0x01]))
    )
    _ = gate.markInterrupted()
    gate.reset()
    let acceptedAfterReset = gate.shouldAccept(
        WSAudioFrame(sequence: 1, opusPayload: Data([0x02]))
    )

    #expect(acceptedBeforeInterrupt == .accept)
    #expect(gate.interruptWatermark == nil)
    #expect(acceptedAfterReset == .accept)
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

@Test func inMemorySecureStorageRoundTripsData() async throws {
    let storage = InMemorySecureStorage()
    let payload = Data("ticket".utf8)
    try await storage.write(payload, key: "session.ticket")
    #expect(try await storage.read(key: "session.ticket") == payload)
    try await storage.delete(key: "session.ticket")
    #expect(try await storage.read(key: "session.ticket") == nil)
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
                try await storage.write(Data("value-\(index)".utf8), key: "key-\(index)")
            }
        }
        try await group.waitForAll()
    }

    for index in 0..<64 {
        #expect(try await storage.read(key: "key-\(index)") == Data("value-\(index)".utf8))
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
    // Use testLocal which defaults to 127.0.0.1 (configurable via TEST_LOCAL_HOST)
    #expect(AppEnvironment.testLocal.apiBaseURL.host == "127.0.0.1")
    #expect(AppEnvironment.testLocal.wssBaseURL.scheme == "ws")
}

@Test func designTokensExposeDarkDefaultPalette() {
    #expect(DesignTokens.Color.backgroundPrimary.hasPrefix("#"))
    #expect(DesignTokens.Typography.titlePointSize == 20)
    #expect(DesignTokens.Motion.standardSeconds == 0.25)
}

@Test func networkConnectivityReducerAppliesSnapshot() throws {
    let store = TGReduxKitTesting.TestStore(
        initialState: NetworkConnectivityState(),
        reducer: networkConnectivityReducer
    )

    var expected = NetworkConnectivityState()
    expected.isConnected = false
    expected.isExpensive = true
    expected.isConstrained = true

    store.send(
        NetworkConnectivityAction.connectivityChanged(
            NetworkPathSnapshot(isConnected: false, isExpensive: true, isConstrained: true)
        )
    )
    try store.assert(equals: expected)
}

@Test func navigationReducerPresentsSpeakingRoomFullScreen() throws {
    let store = TGReduxKitTesting.TestStore(
        initialState: AppNavigationState(),
        reducer: appNavigationReducer
    )

    var expected = AppNavigationState()
    expected.workbench.presentedRoute = .speakingRoom(sessionID: "s1")
    expected.workbench.presentationStyle = .fullScreenCover

    store.send(
        AppNavigationAction.workbench(.present(.speakingRoom(sessionID: "s1"), style: .fullScreenCover))
    )
    try store.assert(equals: expected)
}

@Test func navigationSelectTabUpdatesSelectedTab() throws {
    let store = TGReduxKitTesting.TestStore(
        initialState: AppNavigationState(),
        reducer: appNavigationReducer
    )

    var expected = AppNavigationState()
    expected.selectedTab = .corpus
    store.send(AppNavigationAction.selectTab(.corpus))
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
    #expect(domain.isEnabled(.dailyRead))
    #expect(!domain.isEnabled(.voiceVadAuto))
}

/// Engine-level voice processing ships **off** until a device run says
/// otherwise (`ios docs/62` T4), and the switch that decides that is one hand
/// edit to `firstWave` plus a line of instructions in the manual.
///
/// That is a revert someone has to remember. This is the reminder: T4's
/// procedure is "add it to `firstWave`, rebuild" — and if the add is never
/// undone, an engine change whose own header says 未真机验证 goes out to every
/// user by default. Failing here is the intended outcome of forgetting.
///
/// When T4 passes, delete this test in the same commit that adds the flag —
/// deliberately, not accidentally.
@Test func voiceProcessingIsNotOnByDefaultUntilDeviceVerified() {
    #expect(
        !FeatureFlagSnapshot.firstWave.isEnabled(.voiceProcessing),
        "engine-level AEC is device-unverified; T4 must pass before this becomes the default"
    )
    #expect(!FeatureFlagSnapshot.firstWave.isEnabled(.voiceVadAuto))
}
