import FluentWorkNetworking
import Testing
@testable import FluentWorkCore

@Test func speakingRoomActionBridgesTransportFailures() {
    let action = SpeakingRoomAction(.failed("Network connection lost."))
    #expect(action == .failed("Network connection lost."))
}

@Test func speakingRoomActionBridgesSocketReadyAndBadge() {
    #expect(SpeakingRoomAction(.socketReady) == .socketReady)
    #expect(SpeakingRoomAction(.badgeHit("表达自然")) == .badgeHit("表达自然"))
    #expect(SpeakingRoomAction(.networkDowngraded) == .networkDowngraded)
}
