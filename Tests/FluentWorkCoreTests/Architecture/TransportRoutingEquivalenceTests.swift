import Testing
import Foundation
import FactoryKit
import FluentWorkDiagnostics
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

// MARK: - 生产路由表：handler 级

/// 用**生产工厂** `makeTransportEventRouter` 驱动，观察它 dispatch 出什么。
///
/// 不建 store、不起泵、不碰状态机：这一层回答的是"表接对了没有"。状态机那一层由
/// `SpeechSessionMiddlewareTests` 的 64 条原样覆盖——两种问题在不同的高度上。
///
/// 这里用的是生产接线本身（同一个工厂、同一份 handler），所以它对"接线时漏掉
/// 一个副作用"是敏感的，而不是对"测试自己拼的表"敏感。
@MainActor
@Suite("生产路由表的接线")
struct ProductionRoutingWiringTests {

    @Test("feedback.badge 会 mark 评测等待，并推动两次 dispatch")
    func badgeHandlerMarksTheEvaluationArrival() async {
        let (router, recorder, evaluationArrival) = makeProductionRouter()

        await router.route(event: .control(.feedbackBadge(
            badge: "ship it",
            phraseBlockID: "block-1",
            tier: .highlight,
            turnID: "turn-1"
        )))

        // 这一句就是整个 shadow 风险的落点。`.feedbackBadge` 同时被
        // `SocketTransportEventMapper` 映过一次——按 mapper 的写法搬 handler，
        // 就会只发 badgeHit、丢掉这个 mark；丢了之后
        // `processingTimeoutEffects` 走 `scheduleEvaluationWaitTask`，
        // 于是**每一轮都白等 `evaluationWait`（默认 20s）**，不报错、只是慢。
        #expect(evaluationArrival.consume(), "badge 到达时没有 mark 评测等待——每轮会白等满窗口")

        // 两次 dispatch：badgeHit（展示）与 .session(.evaluationReceived)（状态机）。
        // 少了后者，阶段不会离开 evaluation；少了前者，界面上没有命中。
        #expect(recorder.actions.count == 2)
        if recorder.actions.count == 2 {
            guard case .speakingRoom(.badgeHit) = recorder.actions[0] else {
                Issue.record("第一次 dispatch 不是 badgeHit：\(recorder.actions[0])")
                return
            }
            guard case .speakingRoom(.session(.evaluationReceived)) = recorder.actions[1] else {
                Issue.record("第二次 dispatch 不是 .session(.evaluationReceived)：\(recorder.actions[1])")
                return
            }
        }
    }

    @Test("网关报错经 fallback 仍然触发会话失败")
    func errorFrameStillTearsTheSessionDown() async {
        let (router, recorder, _) = makeProductionRouter()

        await router.route(event: .control(.error(code: "provider_audio_failed", message: nil)))

        // `.error` 没有专属 handler，靠 fallback 的 mapper 变成 `.session(.failed)`。
        // 走 router 之后这条路径必须还在——否则网关报错时房间就那样挂着。
        #expect(recorder.actions.count == 1)
        guard let first = recorder.actions.first,
              case .speakingRoom(.session(.failed)) = first
        else {
            Issue.record("`.error` 没有变成 .session(.failed)，实际：\(recorder.actions)")
            return
        }
    }

    @Test("13 类没有专属 handler 的控制帧什么都不做")
    func unownedControlFramesChangeNothing() async {
        let unowned: [WSControlFrame] = [
            .auth(ticket: "t"),
            .handshake(ticket: "t", sessionID: "s"),
            .sessionReady(sessionID: "s", userID: nil),
            .sessionStart(.init(materialID: "m")),
            .userSpeechStart,
            .userSpeechEnd(text: nil, turnID: "turn-1"),
            .clientTurnAbort(turnID: "turn-1", outcome: .userAbandoned),
            .aiAudioChunk(sequence: 1),
            .interrupt,
            .sessionEnd(reason: nil),
            .ping(ts: 1),
            .pong(ts: 1),
            // `.error` 不在此列：它是这 13 类里唯一有动作的，见上一条。
        ]

        for frame in unowned {
            let (router, recorder, evaluationArrival) = makeProductionRouter()
            await router.route(event: .control(frame))
            #expect(
                recorder.actions.isEmpty,
                "\(frame.wireType) 产生了 dispatch：\(recorder.actions) —— 它本该被 mapper 有意忽略"
            )
            #expect(!evaluationArrival.consume(), "\(frame.wireType) 意外地 mark 了评测等待")
        }
    }

    /// 被丢弃的音频帧不是「AI 开始说话了」——它一声不响。
    ///
    /// `.aiFirstAudioChunk` 是 `.aiSpeaking` 的唯一入口（`SpeechSessionMachine.swift:191`）。
    /// 为一个协调器已经判死的帧发它，症状是「房间说 AI 在说话、实际没有声音」，
    /// 而 `first_response_ms` 会被这条并不存在的音频污染；又因为
    /// `markTurnOnce` / `markFirstResponse` **每轮只报一次**，真正的那一帧再也纠正不了。
    ///
    /// 这条对「先 dispatch、后判定」的实现是红的。
    @Test("无归属的音频帧不得宣告 aiFirstAudioChunk")
    func droppedAudioFrameDoesNotAnnounceFirstChunk() async {
        let (router, recorder, _) = makeProductionRouter()

        // 没有 `ai.tts.start`：协调器把这一帧判成 `.unknownTurn` 丢掉。
        await router.route(event: .audio(WSAudioFrame(sequence: 0, payload: Data([0x01, 0x02]))))

        #expect(
            !recorder.actions.contains(where: isFirstAudioChunk),
            "被丢弃的帧宣告了 aiFirstAudioChunk：\(recorder.actions)"
        )
    }

    /// 上一条的反面：有归属的帧仍然要宣告。
    ///
    /// 少了这一条，「干脆不发 aiFirstAudioChunk」也能让上一条变绿——而那样房间
    /// 永远不会离开 `.processing`，等于用另一种静音换掉这一种。
    @Test("有归属的音频帧仍然宣告 aiFirstAudioChunk")
    func playedAudioFrameStillAnnouncesFirstChunk() async {
        let (router, recorder, _) = makeProductionRouter()

        await router.route(
            event: .control(
                .aiTTSStart(turnID: "turn-1", voiceID: "v", sampleRate: 16_000, codec: "pcm")
            )
        )
        await router.route(event: .audio(WSAudioFrame(sequence: 0, payload: Data([0x01, 0x02]))))

        #expect(
            recorder.actions.contains(where: isFirstAudioChunk),
            "有归属的帧没有宣告 aiFirstAudioChunk，房间会卡在 .processing：\(recorder.actions)"
        )
    }
}

/// 这条动作是不是 `.aiFirstAudioChunk`。
private func isFirstAudioChunk(_ action: AppAction) -> Bool {
    if case .speakingRoom(.session(.aiFirstAudioChunk)) = action { return true }
    return false
}

/// 用生产工厂搭一个路由器，dispatch 落进 `recorder`。
@MainActor
private func makeProductionRouter() -> (TransportEventRouter, ActionRecorder, EvaluationArrivalBox) {
    let container = Container()
    container.reset()
    let recorder = ActionRecorder()
    let evaluationArrival = EvaluationArrivalBox()
    let dispatchBox = MainActorActionBox(dispatch: { recorder.record($0) })

    let router = makeTransportEventRouter(
        container: container,
        dispatchBox: dispatchBox,
        timings: SpeechSessionTimingsRecorder(tracker: ConsoleTracker(), clock: { Date() }),
        turnTimeoutTracking: TurnTimeoutTracking(),
        evaluationArrival: evaluationArrival,
        ttsCoordinator: TTSPlaybackCoordinator(decoder: NoopFrameDecoder(), sink: NoopAudioSink()),
        ttsTrace: TTSStreamTrace()
    )
    return (router, recorder, evaluationArrival)
}

/// 收集被 dispatch 的动作。`@MainActor` 是因为 `MainActorActionBox` 的 dispatch
/// 本来就跑在 MainActor 上。
@MainActor
private final class ActionRecorder {
    private(set) var actions: [AppAction] = []

    func record(_ action: AppAction) {
        actions.append(action)
    }
}

/// 这些测试不碰音频路径，解码器只需存在。
private struct NoopFrameDecoder: AudioFrameDecoder {
    func decode(_ frame: TurnKeyedAudioFrame) async throws -> Data {
        frame.payload
    }
}

/// 同上：不播、不中断。
private struct NoopAudioSink: AudioSink {
    func play(pcm: Data) async {}
    func interruptNow() async {}
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
