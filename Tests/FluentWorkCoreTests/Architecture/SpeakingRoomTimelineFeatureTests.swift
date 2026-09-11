import FluentWorkNetworking
import Testing
import TGReduxKitTesting
@testable import FluentWorkCore

@Test func userTurnTimelineStartsWithListeningThenServerTranscript() {
    let store = TestStore(initialState: AppState.initial, reducer: appReducer)

    store.send(.speakingRoom(.userTurnStarted(turnID: "turn-1")))
    #expect(store.state.speakingRoom.timeline.count == 1)
    let listening = store.state.speakingRoom.timeline[0]
    #expect(listening.speaker == .user)
    #expect(listening.status == .listening)
    #expect(listening.text == "我正在听…")

    store.send(.speakingRoom(.serverASRReceived(text: "Let's ship it today", turnID: "turn-1")))
    let finalized = store.state.speakingRoom.timeline[0]
    #expect(finalized.text == "Let's ship it today")
    #expect(finalized.status == .finalized)
    #expect(store.state.speakingRoom.liveTranscript == "Let's ship it today")
}

@Test func serverTranscriptReplacesLatestListeningWhenProviderTurnIDDiffers() {
    let store = TestStore(initialState: AppState.initial, reducer: appReducer)

    // Client turn numbering (turn-1) and provider volc-turn-1 differ; the open
    // listening row must still be replaced by the authoritative transcript.
    store.send(.speakingRoom(.userTurnStarted(turnID: "turn-1")))
    store.send(.speakingRoom(.serverASRReceived(text: "Let's ship it today", turnID: "volc-turn-1")))

    let row = store.state.speakingRoom.timeline.last
    #expect(row?.text == "Let's ship it today")
    #expect(row?.status == .finalized)
    #expect(row?.turnID == "turn-1")
}

@Test func assistantTurnAccumulatesDeltasAndFinalizes() {
    let store = TestStore(initialState: AppState.initial, reducer: appReducer)

    store.send(.speakingRoom(.aiTurnTextDelta(text: "Nice! ", turnID: nil)))
    store.send(.speakingRoom(.aiTurnTextDelta(text: "Keep going.", turnID: nil)))
    #expect(store.state.speakingRoom.timeline.last?.speaker == .ai)
    #expect(store.state.speakingRoom.timeline.last?.text == "Nice! Keep going.")
    #expect(store.state.speakingRoom.timeline.last?.status == .streaming)

    store.send(.speakingRoom(.aiTurnFinalized(turnID: nil)))
    #expect(store.state.speakingRoom.timeline.last?.status == .finalized)
}

@Test func badgeHitAttachesToCurrentUserTurnAndDeduplicates() {
    let store = TestStore(initialState: AppState.initial, reducer: appReducer)

    store.send(.speakingRoom(.userTurnStarted(turnID: "turn-1")))
    store.send(.speakingRoom(.serverASRReceived(text: "Let's ship it today", turnID: "turn-1")))
    store.send(.speakingRoom(.badgeHit(
        badge: "Let's ship it.",
        phraseBlockID: "block-1",
        tier: .badgeOnly,
        turnID: "turn-1"
    )))
    store.send(.speakingRoom(.badgeHit(
        badge: "Let's ship it.",
        phraseBlockID: "block-1",
        tier: .badgeOnly,
        turnID: "turn-1"
    )))

    let userItem = store.state.speakingRoom.timeline.last
    #expect(userItem?.hits.count == 1)
    #expect(userItem?.hits.first?.badge == "Let's ship it.")
    #expect(userItem?.hits.first?.phraseBlockID == "block-1")
}

/// **This test used to assert the opposite**, and the flip is the fix: the
/// timeline no longer empties when a session enters `.connecting`. See
/// `applySessionConnectingKeepsWhatTheUserWasLookingAt` for why.
@MainActor
@Test func connectingSessionKeepsPreviousTimeline() {
    let store = makeStoreWithOneTimelineItem()

    store.send(.speakingRoom(.applySession(SpeechSessionState(phase: .connecting))))

    #expect(store.state.speakingRoom.timeline.map(\.text) == ["previous"])
}

/// A fresh room clears, and that is the *only* thing that clears now. Without
/// it, entering the room tomorrow would still show yesterday's turns — a room
/// that never forgets is as wrong as one that always does.
@MainActor
@Test func enteringAFreshRoomClearsTheTimeline() {
    let store = makeStoreWithOneTimelineItem()

    store.send(.speakingRoom(.enterRoom(continueFrom: nil)))

    #expect(store.state.speakingRoom.timeline.isEmpty)
    #expect(store.state.speakingRoom.continueFromSessionID == nil)
}

/// Opening a past session fills the room with that session's turns, so
/// 继续 starts from something instead of from a blank screen.
@MainActor
@Test func enteringToContinueSeedsTheTimeline() {
    let store = makeStoreWithOneTimelineItem()

    store.send(.speakingRoom(.enterRoom(
        continueFrom: "s-yesterday",
        seeding: [
            SessionUtterance(seq: 1, speaker: "user", text: "how do I say 限流?"),
            SessionUtterance(seq: 2, speaker: "ai", text: "Rate limiting.")
        ]
    )))

    #expect(store.state.speakingRoom.continueFromSessionID == "s-yesterday")
    #expect(store.state.speakingRoom.timeline.map(\.text) == ["how do I say 限流?", "Rate limiting."])
    #expect(store.state.speakingRoom.timeline.map(\.speaker) == [.user, .ai])
    // Seeded turns are history: nothing is still arriving, and giving them a
    // turn id would let a badge land on a conversation from last week.
    #expect(store.state.speakingRoom.timeline.allSatisfy { $0.status == .finalized })
    #expect(store.state.speakingRoom.timeline.allSatisfy { $0.turnID == nil })
}

/// SwiftUI may fire `onAppear` more than once for one presentation. The entry
/// is the only thing that clears, so a re-fire during a live session would
/// delete the conversation the user is in the middle of — this is the guard
/// that makes making `onAppear` destructive safe.
@Test func aRoomEntryDuringALiveSessionIsIgnored() {
    var state = AppState.initial
    state.speakingRoom = SpeakingRoomState(
        phase: .recording,
        timeline: [
            TurnTimelineItem(turnID: "turn-1", speaker: .user, text: "mid-sentence", status: .streaming)
        ]
    )
    let store = TestStore(initialState: state, reducer: appReducer)

    store.send(.speakingRoom(.enterRoom(continueFrom: nil)))
    #expect(store.state.speakingRoom.timeline.map(\.text) == ["mid-sentence"])
}

@MainActor
private func makeStoreWithOneTimelineItem() -> TestStore<AppState, AppAction> {
    var state = AppState.initial
    state.speakingRoom.timeline = [
        TurnTimelineItem(
            turnID: "turn-1",
            speaker: .user,
            text: "previous",
            status: .finalized
        )
    ]
    return TestStore(initialState: state, reducer: appReducer)
}
