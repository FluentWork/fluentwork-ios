import Testing
import Foundation
import FluentWorkNetworking
@testable import FluentWorkCore

/// 路由接线的等价性。
///
/// `TransportEventRouterTests` 验的是路由器自己的契约，它手里的路由表是测试拼的。
/// 这里验的是**接线**：真实的那张表覆盖了哪些类型、没覆盖的落到哪里、以及
/// 一个今天被硬编码丢掉的事件（`.failure`）确实能被路由出去。
@Suite("路由接线的等价性")
struct TransportRoutingEquivalenceTests {

    /// 生产表**应当**注册的类型：六个有专属 handler 的控制帧。
    ///
    /// 其余 13 类走 fallback，与接线前逐字一致——它们原本就落在 pump 的
    /// `default` 臂、由 `SocketTransportEventMapper` 有意忽略。这不是路由表漏了。
    static let ownedTypes: [WSControlFrameType] = [
        .aiTTSStart,
        .aiTTSEnd,
        .feedbackBadge,
        .aiTurnEnd,
        .aiTextDelta,
        .clientASRTranscription,
    ]

    /// 全部 19 类控制帧各一个样本。
    ///
    /// 用字面量数组而不是循环构造：新增一类 `WSControlFrame` 时，这里不会自动
    /// 跟上——但样本表的断言 `count == WSControlFrameType.allCases.count` 会红，
    /// 那正是要的。
    static let sampleFrames: [WSControlFrame] = [
        .auth(ticket: "ticket-1"),
        .sessionReady(sessionID: "session-1", userID: nil),
        .handshake(ticket: "ticket-1", sessionID: "session-1"),
        .sessionStart(.init(materialID: "m-1")),
        .userSpeechStart,
        .userSpeechEnd(text: nil, turnID: "turn-1"),
        .clientTurnAbort(turnID: "turn-1", outcome: .userAbandoned),
        .clientASRTranscription(text: "hello", turnID: "turn-1"),
        .aiTextDelta(text: "hi", turnID: "turn-1", serverTsMs: 1),
        .aiAudioChunk(sequence: 1),
        .aiTTSStart(turnID: "turn-1", voiceID: "v", sampleRate: 16000, codec: "pcm"),
        .aiTTSEnd(turnID: "turn-1", completionStatus: "ok", durationMs: 100),
        .aiTurnEnd(turnID: "turn-1", outcome: .ok, logID: nil),
        .interrupt,
        .feedbackBadge(badge: "green_check", phraseBlockID: "b-1", tier: .highlight, turnID: "turn-1"),
        .sessionEnd(reason: nil),
        .error(code: "test_error", message: "boom"),
        .ping(ts: 1),
        .pong(ts: 1),
    ]

    @Test("样本表覆盖了全部控制帧类型，且每类恰好一个")
    func sampleTableCoversEveryTypeExactlyOnce() {
        // 一个类型出现在两个样本里，会让下面的"恰好一个 owner"变成假阳性——
        // 那种重复正是手工维护的镜像最容易出的错。
        for frame in Self.sampleFrames {
            let sameType = Self.sampleFrames.filter { $0.wireType == frame.wireType }
            #expect(sameType.count == 1, "\(frame.wireType) 在样本表里出现了 \(sameType.count) 次")
        }
        #expect(Self.sampleFrames.count == WSControlFrameType.allCases.count)
        #expect(Set(Self.sampleFrames.map(\.wireType)).count == WSControlFrameType.allCases.count)
    }

    @Test("每一类控制帧恰好被一个 owner 接走")
    func routerDispatchesEveryControlFrameToExactlyOneOwner() async {
        let log = DispatchLog()
        var handlers: [WSControlFrameType: ControlFrameHandler] = [:]
        for type in Self.ownedTypes {
            handlers[type] = AnyControlFrameHandler { frame in
                await log.noteOwned(type: type, frame: frame)
            }
        }
        let router = TransportEventRouter(
            controlHandlers: handlers,
            fallbackHandler: AnyTransportEventHandler { event in
                await log.noteFallback(event: event)
            }
        )

        for frame in Self.sampleFrames {
            await router.route(event: .control(frame))
        }

        let owned = await log.ownedTypes
        let fallen = await log.fallbackControlTypes

        // 六个各有专属 handler 的，只被自己的那个接走。
        #expect(owned == Set(Self.ownedTypes))
        // 其余 13 类，全部落到 fallback，且一个不少。
        let unowned = Set(WSControlFrameType.allCases).subtracting(Set(Self.ownedTypes))
        #expect(fallen == unowned)
        // 没有哪一类既走专属又走 fallback。
        #expect(owned.isDisjoint(with: fallen))
    }

    @Test("socket 失败被路由，而不是被丢掉")
    func socketFailureIsRoutedRatherThanDropped() async {
        let log = DispatchLog()
        let router = TransportEventRouter(
            fallbackHandler: AnyTransportEventHandler { event in
                await log.noteFallback(event: event)
            }
        )

        await router.route(event: .failure(.network("boom")))
        await router.route(event: .failure(.pingTimedOut))

        // 路由器的旧实现把 `.failure` 硬编码成"忽略"：socket 断了，什么都没发生，
        // 房间就那样挂着。这条测试对那个实现是红的。
        let events = await log.fallbackEvents
        #expect(events.count == 2)
        #expect(events.contains(.failure(.network("boom"))))
        #expect(events.contains(.failure(.pingTimedOut)))
    }
}

// MARK: - 记录

/// 记录每个事件被交给了谁。
private actor DispatchLog {
    private var owned: Set<WSControlFrameType> = []
    private var fallback: [SocketTransportEvent] = []

    var ownedTypes: Set<WSControlFrameType> { owned }

    var fallbackEvents: [SocketTransportEvent] { fallback }

    var fallbackControlTypes: Set<WSControlFrameType> {
        Set(fallback.compactMap { event in
            if case let .control(frame) = event { return frame.wireType }
            return nil
        })
    }

    func noteOwned(type: WSControlFrameType, frame: WSControlFrame) async {
        owned.insert(type)
    }

    func noteFallback(event: SocketTransportEvent) async {
        fallback.append(event)
    }
}
