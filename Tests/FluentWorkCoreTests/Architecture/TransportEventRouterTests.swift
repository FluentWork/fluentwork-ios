import Testing
import Foundation
import FluentWorkNetworking
@testable import FluentWorkCore

/// `TransportEventRouter` 自己的契约。
///
/// 这里只验"事件交给了谁"。路由的**生产**表注册了哪些类型、以及接线后行为是否
/// 等价，在 `TransportRoutingEquivalenceTests` 里——这个文件手里的表是测试自己
/// 拼的，它证明不了生产接线是对的。
@Suite("TransportEventRouter 路由逻辑")
struct TransportEventRouterTests {

    @Test("音频帧路由到 AudioFrameHandler")
    func audioFrameRoutesToAudioHandler() async {
        let recorder = RecordingAudioHandler()
        let router = TransportEventRouter(audioHandler: recorder)

        let frame = WSAudioFrame(sequence: 42, payload: Data([0x01, 0x02]))
        await router.route(event: .audio(frame))

        let calls = await recorder.calls
        #expect(calls.count == 1)
        #expect(calls[0].sequence == 42)
    }

    @Test("没有 AudioHandler 时音频帧落到 fallback")
    func audioFrameWithoutHandlerReachesTheFallback() async {
        let fallback = RecordingTransportHandler()
        let router = TransportEventRouter(fallbackHandler: fallback)

        await router.route(event: .audio(WSAudioFrame(sequence: 1, payload: Data([0x01]))))

        let calls = await fallback.calls
        #expect(calls.count == 1)
    }

    @Test("既没有 handler 也没有 fallback 时，音频帧被安静地放下")
    func audioFrameWithoutAnyHandlerIsDropped() async {
        let router = TransportEventRouter()

        // 不崩溃、不抛出——"无人认领"不是错误。
        await router.route(event: .audio(WSAudioFrame(sequence: 1, payload: Data([0x01]))))
    }

    @Test("控制帧路由到对应的 ControlFrameHandler")
    func controlFrameRoutesToCorrectHandler() async {
        let aiTextHandler = RecordingControlHandler()
        let aiTurnEndHandler = RecordingControlHandler()

        let router = TransportEventRouter(
            controlHandlers: [
                .aiTextDelta: aiTextHandler,
                .aiTurnEnd: aiTurnEndHandler,
            ]
        )

        let textDelta = WSControlFrame.aiTextDelta(text: "hello", turnID: "turn-1", serverTsMs: 12345)
        let turnEnd = WSControlFrame.aiTurnEnd(turnID: "turn-1", outcome: .ok, logID: nil)

        await router.route(event: .control(textDelta))
        await router.route(event: .control(turnEnd))

        let textCalls = await aiTextHandler.calls
        let turnCalls = await aiTurnEndHandler.calls

        #expect(textCalls.count == 1)
        #expect(turnCalls.count == 1)
        // 路由必须按类型分清，不是"随便给一个 handler 就算数"。
        #expect(textCalls[0].wireType == .aiTextDelta)
        #expect(turnCalls[0].wireType == .aiTurnEnd)
    }

    @Test("未注册的控制帧落到 fallback")
    func unregisteredControlFrameReachesTheFallback() async {
        let fallback = RecordingTransportHandler()
        let router = TransportEventRouter(
            controlHandlers: [.aiTextDelta: RecordingControlHandler()],
            fallbackHandler: fallback
        )

        let turnEnd = WSControlFrame.aiTurnEnd(turnID: "turn-1", outcome: .ok, logID: nil)
        await router.route(event: .control(turnEnd))

        let calls = await fallback.calls
        #expect(calls.count == 1)
        if case let .control(frame) = calls[0] {
            #expect(frame.wireType == .aiTurnEnd)
        } else {
            Issue.record("fallback 收到的不是控制帧：\(calls[0])")
        }
    }

    @Test("已注册的控制帧不会同时落到 fallback")
    func registeredControlFrameDoesNotAlsoReachTheFallback() async {
        let handler = RecordingControlHandler()
        let fallback = RecordingTransportHandler()
        let router = TransportEventRouter(
            controlHandlers: [.aiTextDelta: handler],
            fallbackHandler: fallback
        )

        await router.route(event: .control(.aiTextDelta(text: "hi", turnID: nil, serverTsMs: nil)))

        #expect(await handler.calls.count == 1)
        #expect(await fallback.calls.isEmpty)
    }

    @Test("诊断事件路由到 DiagnosticHandler")
    func diagnosticEventRoutesToDiagnosticHandler() async {
        let handler = RecordingTransportHandler()
        let router = TransportEventRouter(diagnosticHandler: handler)

        // Any diagnostic will do: this test is about the router sending every
        // diagnostic to the diagnostic handler. (This used to be
        // `.audioFrameDropped`, which went with the transport's sequence
        // watermark — see `18_删除传输层序号水印.md`.)
        let diagnostic = SocketTransportEvent.diagnostic(
            .receiveLatency(frameType: "audio_binary", sizeBytes: 644, elapsedMs: 0.5)
        )
        await router.route(event: diagnostic)

        let calls = await handler.calls
        #expect(calls.count == 1)
    }

    @Test("状态变化事件落到 fallback")
    func stateChangeEventReachesTheFallback() async {
        let fallback = RecordingTransportHandler()
        let router = TransportEventRouter(fallbackHandler: fallback)

        await router.route(event: .stateChanged(.connected))

        let calls = await fallback.calls
        #expect(calls.count == 1)
    }
}

// MARK: - 测试辅助类型

/// 记录所有音频帧处理调用
private actor RecordingAudioHandler: AudioFrameHandler {
    var calls: [WSAudioFrame] = []

    func handle(frame: WSAudioFrame) async {
        calls.append(frame)
    }
}

/// 记录所有控制帧处理调用
private actor RecordingControlHandler: ControlFrameHandler {
    var calls: [WSControlFrame] = []

    func handle(frame: WSControlFrame) async {
        calls.append(frame)
    }
}

/// 记录所有传输事件处理调用
private actor RecordingTransportHandler: TransportEventHandler {
    var calls: [SocketTransportEvent] = []

    func handle(event: SocketTransportEvent) async {
        calls.append(event)
    }
}
