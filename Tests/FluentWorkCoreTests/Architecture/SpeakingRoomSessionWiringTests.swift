import FactoryKit
import Foundation
import Testing
import TGReduxKitTesting
@testable import FluentWorkCore

@Test func applySessionConnectingResetsBadgeAndTranscript() throws {
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
    expected.speakingRoom.session = SpeechSessionState(phase: .connecting)
    expected.speakingRoom.liveTranscript = ""
    expected.speakingRoom.lastBadge = nil
    expected.speakingRoom.badgeHits = 0

    store.send(.speakingRoom(.applySession(SpeechSessionState(phase: .connecting))))
    try store.assert(equals: expected)
}

@Test func rawSessionEventsDoNotMutateStateInReducer() throws {
    let initial = AppState(
        speakingRoom: SpeakingRoomState(
            phase: .failed,
            isBootstrapReady: true,
            failureReason: "网络错误"
        )
    )
    let store = TestStore(initialState: initial, reducer: appReducer)

    store.send(.speakingRoom(.session(.socketReady)))
    try store.assert(equals: initial)
    store.send(.speakingRoom(.session(.networkLost)))
    try store.assert(equals: initial)
}

@MainActor
@Test func speechSessionMiddlewareAppliesMachineOutput() async {
    Container.shared.reset()
    defer { Container.shared.reset() }

    let store = AppStoreFactory.make()
    store.dispatch(.speakingRoom(.session(.sessionStartTap)))
    try? await Task.sleep(nanoseconds: 20_000_000)

    #expect(store.state.speakingRoom.phase == .connecting)

    store.dispatch(.speakingRoom(.session(.socketReady)))
    try? await Task.sleep(nanoseconds: 20_000_000)
    #expect(store.state.speakingRoom.phase == .aiSpeaking)
}
