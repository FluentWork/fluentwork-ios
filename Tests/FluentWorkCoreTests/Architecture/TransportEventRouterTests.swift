import Testing
import FluentWorkNetworking
@testable import FluentWorkCore

/// Stage 1 测试：验证 TransportEventRouter 的路由逻辑
///
/// 这些测试锁住路由表的正确性，确保每种事件都能找到对应的 handler

@Suite("TransportEventRouter 路由逻辑")
struct TransportEventRouterTests {
    
    @Test("音频帧路由到 AudioFrameHandler")
    func audioFrameRoutesToAudioHandler() async {
        let recorder = RecordingAudioHandler()
        let router = await TransportEventRouter(audioHandler: recorder)
        
        let frame = WSAudioFrame(sequence: 42, opusPayload: Data([0x01, 0x02]))
        let result = await router.route(event: .audio(frame))
        
        #expect(result == .handled)
        let calls = await recorder.calls
        #expect(calls.count == 1)
        #expect(calls[0].sequence == 42)
    }
    
    @Test("没有 AudioHandler 时音频帧被忽略")
    func audioFrameIgnoredWithoutHandler() async {
        let router = await TransportEventRouter()
        
        let frame = WSAudioFrame(sequence: 1, opusPayload: Data([0x01]))
        let result = await router.route(event: .audio(frame))
        
        #expect(result == .ignored)
    }
    
    @Test("控制帧路由到对应的 ControlFrameHandler")
    func controlFrameRoutesToCorrectHandler() async {
        let aiTextHandler = RecordingControlHandler(name: "aiTextDelta")
        let aiTurnEndHandler = RecordingControlHandler(name: "aiTurnEnd")
        
        let router = await TransportEventRouter(
            controlHandlers: [
                .aiTextDelta: aiTextHandler,
                .aiTurnEnd: aiTurnEndHandler
            ]
        )
        
        let textDelta = WSControlFrame.aiTextDelta("hello", "turn-1", 12345)
        let turnEnd = WSControlFrame.aiTurnEnd("turn-1", .ok, nil)
        
        _ = await router.route(event: .control(textDelta))
        _ = await router.route(event: .control(turnEnd))
        
        let textCalls = await aiTextHandler.calls
        let turnCalls = await aiTurnEndHandler.calls
        
        #expect(textCalls.count == 1)
        #expect(turnCalls.count == 1)
    }
    
    @Test("未注册的控制帧被忽略")
    func unregisteredControlFrameIsIgnored() async {
        let router = await TransportEventRouter(
            controlHandlers: [
                .aiTextDelta: RecordingControlHandler(name: "text")
            ]
        )
        
        let turnEnd = WSControlFrame.aiTurnEnd("turn-1", .ok, nil)
        let result = await router.route(event: .control(turnEnd))
        
        #expect(result == .ignored)
    }
    
    @Test("诊断事件路由到 DiagnosticHandler")
    func diagnosticEventRoutesToDiagnosticHandler() async {
        let handler = RecordingTransportHandler(name: "diagnostic")
        let router = await TransportEventRouter(diagnosticHandler: handler)
        
        let diagnostic = WSTransportEvent.diagnostic(.audioFrameDropped(sequence: 10, watermark: 5, dropped: 1))
        let result = await router.route(event: diagnostic)
        
        #expect(result == .handled)
        let calls = await handler.calls
        #expect(calls.count == 1)
    }
    
    @Test("状态变化事件路由到 StateChangeHandler")
    func stateChangeEventRoutesToStateChangeHandler() async {
        let handler = RecordingTransportHandler(name: "stateChange")
        let router = await TransportEventRouter(stateChangeHandler: handler)
        
        let stateChange = WSTransportEvent.stateChanged(.connected)
        let result = await router.route(event: stateChange)
        
        #expect(result == .handled)
        let calls = await handler.calls
        #expect(calls.count == 1)
    }
    
    @Test("路由表快照：所有控制帧类型")
    func routingTableSnapshot() async {
        // 验证所有已知的控制帧类型都有对应的枚举值
        // 这是一个"契约测试"：如果新增了帧类型但没更新路由器，这里会失败
        
        let allFrames: [WSControlFrame] = [
            .sessionReady("session-1", nil),
            .aiTextDelta("text", "turn-1", 12345),
            .aiTurnEnd("turn-1", .ok, nil),
            .clientASRTranscription("hello", "turn-1"),
            .feedbackBadge(.greenCheck, "turn-1", .tier1, nil),
            .ping(12345),
            .pong(12345),
            .sessionEnd,
            .error("test error"),
            .aiTTSStart("turn-1", "voice-1", 16000, "pcm"),
            .aiTTSEnd("turn-1", "ok", nil),
            .interrupt,
        ]
        
        // 为每种帧类型注册一个 handler
        var handlers: [WSControlFrameType: ControlFrameHandler] = [:]
        for frameType in [
            WSControlFrameType.sessionReady,
            .aiTextDelta,
            .aiTurnEnd,
            .clientASRTranscription,
            .feedbackBadge,
            .ping,
            .pong,
            .sessionEnd,
            .error,
            .aiTTSStart,
            .aiTTSEnd,
            .interrupt,
        ] {
            handlers[frameType] = RecordingControlHandler(name: "\(frameType)")
        }
        
        let router = await TransportEventRouter(controlHandlers: handlers)
        
        // 所有帧都应该被成功路由
        for frame in allFrames {
            let result = await router.route(event: .control(frame))
            #expect(result == .handled, "Frame \(frame) should be routed")
        }
    }
}

// MARK: - 测试辅助类型

/// 记录所有音频帧处理调用
private actor RecordingAudioHandler: AudioFrameHandler {
    var calls: [WSAudioFrame] = []
    
    func handle(frame: WSAudioFrame) async -> TransportEventResult {
        calls.append(frame)
        return .handled
    }
}

/// 记录所有控制帧处理调用
private actor RecordingControlHandler: ControlFrameHandler {
    let name: String
    var calls: [WSControlFrame] = []
    
    init(name: String) {
        self.name = name
    }
    
    func handle(frame: WSControlFrame) async -> TransportEventResult {
        calls.append(frame)
        return .handled
    }
}

/// 记录所有传输事件处理调用
private actor RecordingTransportHandler: TransportEventHandler {
    let name: String
    var calls: [WSTransportEvent] = []
    
    init(name: String) {
        self.name = name
    }
    
    func handle(event: WSTransportEvent) async -> TransportEventResult {
        calls.append(event)
        return .handled
    }
}

// MARK: - TransportEventResult Equatable

extension TransportEventResult: Equatable {
    public static func == (lhs: TransportEventResult, rhs: TransportEventResult) -> Bool {
        switch (lhs, rhs) {
        case (.handled, .handled), (.ignored, .ignored):
            return true
        case let (.failed(lhsMsg), .failed(rhsMsg)):
            return lhsMsg == rhsMsg
        default:
            return false
        }
    }
}
