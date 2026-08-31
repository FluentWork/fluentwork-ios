import FluentWorkNetworking
import Testing
@testable import FluentWorkCore

@Test func speakingRoomActionBridgesTransportFailures() {
    let action = SpeakingRoomAction(.failed("Network connection lost."))
    #expect(action == .session(.failed("Network connection lost.")))
}

@Test func speakingRoomActionBridgesSocketReadyAndBadge() {
    #expect(SpeakingRoomAction(.socketReady) == .session(.socketReady))
    #expect(SpeakingRoomAction(.badgeHit("表达自然")) == .badgeHit("表达自然"))
    #expect(SpeakingRoomAction(.networkLost) == .session(.networkLost))
}
