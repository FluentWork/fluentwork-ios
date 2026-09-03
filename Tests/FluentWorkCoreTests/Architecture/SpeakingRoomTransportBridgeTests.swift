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

@Test func mapperConvertsBackendErrorFrameToFailedAction() {
    // Mirrors the production payload emitted by voicegateway.handler when a
    // volc-duplex audio forward fails (the connection died mid-turn).
    let event = SocketTransportEvent.control(
        .error(code: "provider_audio_failed", message: "use of closed network connection")
    )
    let action = SocketTransportEventMapper.speakingRoomAction(for: event)
    #expect(action == .failed("语音服务连接中断，请重试"))
}

@Test func mapperConvertsBackendErrorFrameWithoutMessage() {
    let event = SocketTransportEvent.control(
        .error(code: "client_asr_required", message: nil)
    )
    let action = SocketTransportEventMapper.speakingRoomAction(for: event)
    #expect(action == .failed("当前无法识别语音，请重试"))
}

@Test func mapperConvertsClientASRTranscriptionToServerASRReceived() {
    let event = SocketTransportEvent.control(
        .clientASRTranscription(text: "we should ship it today", turnID: "turn-1")
    )
    let action = SocketTransportEventMapper.speakingRoomAction(for: event)
    #expect(action == .serverASRReceived(text: "we should ship it today", turnID: "turn-1"))
}
