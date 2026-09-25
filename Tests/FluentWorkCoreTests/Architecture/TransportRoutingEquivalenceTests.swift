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

    /// 生产表**应当**注册的类型：七个有专属 handler 的控制帧。
    ///
    /// 其余 13 类走 fallback——其中 12 类被 mapper 有意忽略、`.error` 触发 teardown。
    /// 这 12 类不是路由表漏了，逐条理由在
    /// `ProductionRoutingWiringTests.unownedControlFramesChangeNothing` 的名单里。
    static let ownedTypes: [WSControlFrameType] = [
        .aiTTSStart,
        .aiTTSEnd,
        .aiAudioChunk,
        .feedbackBadge,
        .aiTurnEnd,
        .aiTextDelta,
        .clientASRTranscription,
    ]

    /// 全部 20 类控制帧各一个样本。
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
        .clientRescueRequest,
        .clientASRTranscription(text: "hello", turnID: "turn-1"),
        .aiTextDelta(text: "hi", turnID: "turn-1", serverTsMs: 1),
        .aiAudioChunk(sequence: 1),
        .aiTTSStart(turnID: "turn-1", voiceID: "v", sampleRate: 16000, codec: "pcm", turnRef: nil),
        .aiTTSEnd(turnID: "turn-1", completionStatus: "ok", durationMs: 100, turnRef: nil),
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

        // 七个各有专属 handler 的，只被自己的那个接走。
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

    /// `ai.audio.chunk` 是**唯一一类会承载音频、却一个 handler 都没有**的控制帧。
    ///
    /// 它解码成功、落 fallback、被 mapper 有意忽略——于是**连一条日志都没有**。
    /// 对照：一个**未知** type 会走 `.unsupportedControlFrame` 诊断、被记成
    /// `transport_control_frame_ignored`（`SocketTransportTests` 有一条钉着），
    /// `ai.tts.audio` 这种不认识的名字也一样。**已知、但没人接**的那一类，
    /// 恰恰是唯一无声的。
    ///
    /// 后端目前没有生产者：`voiceproto/frames.go:21` 只有常量声明，全仓再无一处引用
    /// （`frames_test.go` 的冻结断言把它记成 "no producer, no consumer, no test,
    /// on either side of the wire"），V2 设计也明确「❌ 不加」。所以这条测试要钉的
    /// 不是"客户端该播这种帧"，而是**它一旦来了必须看得见**——音频改走控制帧、
    /// 客户端仍只播二进制帧，用户听到的是安静，而日志里什么都没有。
    ///
    /// 这条对「它落在 fallback、mapper 返回 nil」的实现是红的。
    @Test("ai.audio.chunk 到达必须留痕，而不是被静默忽略")
    func audioChunkControlFrameLeavesATrace() async {
        let tracker = CapturingTracker()
        let (router, recorder, _) = makeProductionRouter(tracker: tracker)

        await router.route(event: .control(.aiAudioChunk(sequence: 7)))

        let trace = tracker.events.first { $0.name == "tts_audio_chunk_ignored" }
        #expect(
            trace != nil,
            "ai.audio.chunk 到达了，日志里却没有一条痕迹：\(tracker.events.map(\.name))"
        )
        #expect(trace?.properties["type"] == "ai.audio.chunk")
        #expect(trace?.properties["sequence"] == "7")
        // 留痕不等于补上播放：客户端没有播这种帧的能力，也不该在这里假装有。
        #expect(recorder.actions.isEmpty, "它不该产生动作：\(recorder.actions)")
    }

    /// 没有专属 handler 的控制帧，逐条写明**为什么**它可以安静。
    ///
    /// 一张"没人接"的名单如果只列类型、不写理由，下一个人就分不清某一项是
    /// **有意忽略**还是**漏了**。D11（`ai.audio.chunk`）正是后者：它在这个名单里
    /// 待过，而没人说得清它为什么在这。所以名单的每一项都带一句理由。
    ///
    /// 断言写成集合相等，于是新增一类 `WSControlFrame` 会让这条红——要么给它
    /// 注册 handler，要么在这里补一条带理由的。这就是"分类不会靠纪律维持"。
    @Test("12 类没有专属 handler 的控制帧什么都不做，且这 12 类逐条写明理由")
    func unownedControlFramesChangeNothing() async {
        let unowned: [(frame: WSControlFrame, reason: String)] = [
            // 只上行：客户端发出去，这一侧收不到。
            (.auth(ticket: "t"), "客户端 → 网关的首帧"),
            (.sessionStart(.init(materialID: "m")), "客户端 → 网关"),
            (.userSpeechStart, "客户端 → 网关"),
            (.userSpeechEnd(text: nil, turnID: "turn-1"), "客户端 → 网关"),
            (.clientTurnAbort(turnID: "turn-1", outcome: .userAbandoned), "客户端 → 网关"),
            (.clientRescueRequest, "客户端 → 网关；梯子从网关走 ai.rescue.ladder 回来"),
            (.interrupt, "客户端 → 网关；网关不回声"),
            (.ping(ts: 1), "客户端 → 网关；网关回的是 pong"),

            // 传输层在 emit 之前已经消费掉了。
            (.pong(ts: 1), "`recordClockOffsetIfPong` 先拿它算时钟偏移，再原样 emit"),

            // 网关的应答：收到即无需动作。
            (.sessionReady(sessionID: "s", userID: nil), "auth 之后客户端自己就 emit 了 .connected，session_id 它本来就有"),
            (.sessionEnd(reason: nil), "客户端自己发的那个帧的回执（`handler_control.go:443`），会话在本地已经拆掉"),

            // 死面：这一侧既不构造、也不接收。
            (.handshake(ticket: "t", sessionID: "s"), "`connect` 发的是 auth（`URLSessionSocketTransport.swift:117`），后端也没有这个常量；只有测试在造它"),

            // `.error` 不在此列：它是落到 fallback 的 12 类里唯一有动作的，见上一条。
        ]

        for (frame, reason) in unowned {
            let (router, recorder, evaluationArrival) = makeProductionRouter()
            await router.route(event: .control(frame))
            #expect(
                recorder.actions.isEmpty,
                "\(frame.wireType) 产生了 dispatch：\(recorder.actions) —— 理由写的是「\(reason)」，那它就不该有动作"
            )
            #expect(!evaluationArrival.consume(), "\(frame.wireType) 意外地 mark 了评测等待")
        }

        // 这 12 类加上 `.error`，正好是 20 − 7：没有哪一类是"谁都没想过"的。
        let classified = Set(unowned.map(\.frame.wireType)).union([.error])
        let unownedByTable = Set(WSControlFrameType.allCases)
            .subtracting(Set(TransportRoutingEquivalenceTests.ownedTypes))
        #expect(
            classified == unownedByTable,
            "有控制帧既没有 handler、也不在这张带理由的名单里：\(unownedByTable.subtracting(classified))"
        )
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
                .aiTTSStart(turnID: "turn-1", voiceID: "v", sampleRate: 16_000, codec: "pcm", turnRef: nil)
            )
        )
        await router.route(event: .audio(WSAudioFrame(sequence: 0, payload: Data([0x01, 0x02]))))

        #expect(
            recorder.actions.contains(where: isFirstAudioChunk),
            "有归属的帧没有宣告 aiFirstAudioChunk，房间会卡在 .processing：\(recorder.actions)"
        )
    }

    /// 一轮音频有上百帧，而「这一轮在丢帧」是**一个事实，不是一个时刻**。
    ///
    /// `.dropped` 分支原来对每一帧 track 一次。在真正要紧的形状里（D2b：一整轮无归属）
    /// 那是每轮上百条 `tts_frame_dropped`，把「这一轮在丢帧」这条真信号埋在自己的重复里。
    ///
    /// 同一形状在 `ai_first_chunk` 上已经修过一次：`08_` §5.2 记「每帧都打（250 帧 = 250 行），
    /// 把真响应的第一条埋掉」，由 `cacfdd2` 用 `markTurnOnce` 改成每轮只报一次。
    /// **同一条链路的丢弃路径留着同一个问题。**
    ///
    /// 这条对「逐帧上报」的实现是红的。
    @Test("一整轮被丢弃只留一条痕迹，不是每帧一条")
    func aWholeDroppedTurnReportsTheReasonOnce() async {
        let tracker = CapturingTracker()
        let (router, _, _) = makeProductionRouter(tracker: tracker)

        // 没有 ai.tts.start：协调器把每一帧都判成 .unknownTurn。
        for sequence in UInt32(0)..<UInt32(250) {
            await router.route(
                event: .audio(WSAudioFrame(sequence: sequence, payload: Data([0x01, 0x02])))
            )
        }

        let drops = tracker.events.filter { $0.name == "tts_frame_dropped" }
        #expect(
            drops.count == 1,
            "250 帧被丢弃留下了 \(drops.count) 条 tts_frame_dropped：这一轮在丢帧是一个事实，不是 250 个时刻"
        )
        #expect(drops.first?.properties["reason"] == "unknownTurn")
        #expect(drops.first?.properties["turn_id"] == "nil")
    }

    /// 上一条的反面：去重**不能变成「一场会话只报一次」**。
    ///
    /// 少了这一条，「第一帧报完之后就再也不报」也能让上一条变绿——而那会让**第二次**
    /// 丢帧事故完全看不见。去重的粒度是「一轮」，不是「一次会话」。
    @Test("下一轮的丢弃仍然要报，去重不是一次性的")
    func theNextTurnsDropsAreStillReported() async {
        let tracker = CapturingTracker()
        let (router, _, _) = makeProductionRouter(tracker: tracker)

        // 第一段：无归属，全部丢弃。
        for sequence in UInt32(0)..<UInt32(5) {
            await router.route(
                event: .audio(WSAudioFrame(sequence: sequence, payload: Data([0x01, 0x02])))
            )
        }
        // 一轮正常起止：`ai.tts.start` 会重置这一轮的台账。
        await router.route(
            event: .control(
                .aiTTSStart(turnID: "turn-1", voiceID: "v", sampleRate: 16_000, codec: "pcm", turnRef: nil)
            )
        )
        await router.route(
            event: .control(.aiTTSEnd(turnID: "turn-1", completionStatus: "ok", durationMs: nil, turnRef: nil))
        )
        // 第二段：又无归属了，全部丢弃。
        for sequence in UInt32(0)..<UInt32(5) {
            await router.route(
                event: .audio(WSAudioFrame(sequence: sequence, payload: Data([0x01, 0x02])))
            )
        }

        let drops = tracker.events.filter { $0.name == "tts_frame_dropped" }
        #expect(
            drops.count == 2,
            "两段各自丢帧，却只留下 \(drops.count) 条痕迹：去重按「一轮」才对，不是按会话"
        )
    }
}

/// 这条动作是不是 `.aiFirstAudioChunk`。
private func isFirstAudioChunk(_ action: AppAction) -> Bool {
    if case .speakingRoom(.session(.aiFirstAudioChunk)) = action { return true }
    return false
}

/// 用生产工厂搭一个路由器，dispatch 落进 `recorder`、埋点落进 `tracker`。
///
/// `tracker` 可传，是因为"这一类帧到了有没有留痕"只能从埋点看——它不产生动作，
/// 所以 `recorder.actions` 对它是瞎的。
@MainActor
private func makeProductionRouter(
    tracker: CapturingTracker = CapturingTracker()
) -> (TransportEventRouter, ActionRecorder, EvaluationArrivalBox) {
    let container = Container()
    container.reset()
    let recorder = ActionRecorder()
    let evaluationArrival = EvaluationArrivalBox()
    container.tracker.register { tracker }
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
