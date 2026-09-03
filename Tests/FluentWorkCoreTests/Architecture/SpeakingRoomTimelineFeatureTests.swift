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

@Test func connectingSessionClearsPreviousTimeline() {
    var state = AppState.initial
    state.speakingRoom.timeline = [
        TurnTimelineItem(
            turnID: "turn-1",
            speaker: .user,
            text: "previous",
            status: .finalized
        )
    ]
    let store = TestStore(initialState: state, reducer: appReducer)

    store.send(.speakingRoom(.applySession(SpeechSessionState(phase: .connecting))))
    #expect(store.state.speakingRoom.timeline.isEmpty)
}
