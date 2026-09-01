import FluentWorkNetworking
import Testing
@testable import FluentWorkCore

@Test func speakingRoomActionBridgesTransportFailures() {
    let action = SpeakingRoomAction(.failed("Network connection lost."))
    #expect(action == .session(.failed("Network connection lost.")))
}

@Test func speakingRoomActionBridgesSocketReadyAndBadge() {
    #expect(SpeakingRoomAction(.socketReady) == .session(.socketReady))
    #expect(
        SpeakingRoomAction(
            .badgeHit(
                badge: "表达自然",
                phraseBlockID: "block-1",
                tier: .highlight,
                turnID: "turn-1"
            )
        ) == .badgeHit(
            badge: "表达自然",
            phraseBlockID: "block-1",
            tier: .nextTurnConfirm, // highlight → nextTurnConfirm
            turnID: "turn-1"
        )
    )
    #expect(SpeakingRoomAction(.networkLost) == .session(.networkLost))
}
