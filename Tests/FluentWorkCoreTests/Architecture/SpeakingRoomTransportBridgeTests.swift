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

@Test func mapperConvertsUnsupportedFrameToFailedAction() {
    // Pre-I20 gateway replied to client.turn.abort with unsupported_frame.
    // iOS still maps that to .failed — 联调 must not see this code after abort.
    //
    // The code is now **retired** (the gateway ignores unknown frame types
    // instead of rejecting them — `handler.go` keeps `unsupported_frame` only
    // in the comments explaining that), so this also covers the unknown-code
    // path: the identifier is kept for diagnostics, but beside a human sentence
    // rather than as the whole message. See `docs/57`.
    let event = SocketTransportEvent.control(
        .error(code: "unsupported_frame", message: "unknown type")
    )
    let action = SocketTransportEventMapper.speakingRoomAction(for: event)
    #expect(action == .failed("语音服务出了点问题，请重试（unsupported_frame: unknown type）"))
}

@Test func mapperConvertsClientASRTranscriptionToServerASRReceived() {
    let event = SocketTransportEvent.control(
        .clientASRTranscription(text: "we should ship it today", turnID: "turn-1")
    )
    let action = SocketTransportEventMapper.speakingRoomAction(for: event)
    #expect(action == .serverASRReceived(text: "we should ship it today", turnID: "turn-1"))
}
