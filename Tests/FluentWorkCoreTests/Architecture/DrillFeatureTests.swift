import FactoryKit
import FluentWorkNetworking
import Foundation
import Testing
@testable import FluentWorkCore

// MARK: - 投影（E2 / E4）

/// 成功率的分母是**作答次数**，不是题数。
///
/// 超时与跳过也算一次作答（机器带着空 `asr_text` 提交，服务端照常判定）——把它们从分母里
/// 摘掉会让成功率虚高，而学员卡住的正是那几次。这条判据特意把 `planned` 设成 10：
/// 若实现改成「通过的卡 / 计划题数」，它会算出 1.0 而不是 10/12。
@Test func successRateCountsAttemptsNotCards() {
    var round = DrillRoundState()
    round.planned = 10
    round.answeredAttempts = 12
    round.passedAttempts = 10

    #expect(DrillState(round: round).successRate == 10.0 / 12.0)
}

/// 一次都没答过时是 `nil`，不是 0 —— 结算页要能区分「一次没答」和「全答错了」。
@Test func thereIsNoSuccessRateBeforeAnyAttempt() {
    #expect(DrillState().successRate == nil)
}

/// 「判定前」要展示的识别文本优先用**服务端识别的那一份**（E2）。
///
/// 这一屏要回答的是「系统听到的是什么」，而那句判定就是照着它下的；本地提交的那句是
/// 我们自己发出去的，两者不一致时，学员要确认的是前者。
@Test func recognitionTextPrefersWhatTheServerHeard() {
    var round = DrillRoundState()
    round.lastSubmission = DrillSubmission(blockID: "b1", asrText: "what we sent", responseMS: 900)
    round.lastVerdict = makeVerdict(judged: false, asrText: "what the server heard")

    #expect(DrillState(round: round).recognitionText == "what the server heard")
}

/// 服务端没给识别文本时，退回本地提交的那句 —— 宁可展示一个旧读数，
/// 也不要空着一屏让学员无从确认。
@Test func recognitionTextFallsBackToWhatWeSent() {
    var round = DrillRoundState()
    round.lastSubmission = DrillSubmission(blockID: "b1", asrText: "what we sent", responseMS: 900)
    round.lastVerdict = makeVerdict(judged: false, asrText: "")

    #expect(DrillState(round: round).recognitionText == "what we sent")
}

/// 一句话都没说过时没有可展示的东西（`nil`，不是空串）：
/// 空串会让「正在确认」那一屏看起来像已经确认过了。
@Test func recognitionTextIsNilWhenNothingWasSaid() {
    var round = DrillRoundState()
    round.lastVerdict = makeVerdict(judged: false, asrText: "")
    #expect(DrillState(round: round).recognitionText == nil)
}

// MARK: - 入口全覆盖

/// 每个「屏幕能发的」action 都必须映射到机器事件。
///
/// 这张表是手写的（枚举里没有可枚举的关联值），所以漏一条编译器不会说话；这条判据替它说话。
/// `applyRound` 是**输出**，必须留在外面 —— 喂回机器会绕成环。
@Test func everyEntranceActionMapsToAMachineEvent() {
    let entrances: [DrillAction] = [
        .startTapped(size: 10, sessionID: nil),
        .readinessElapsed(at: Date(timeIntervalSince1970: 0)),
        .answerDeadlineReached,
        .answerCaptured(asrText: "x", at: Date(timeIntervalSince1970: 0)),
        .skipTapped(at: Date(timeIntervalSince1970: 0)),
        .retryTapped,
        .advanceTapped,
        .appealTapped,
        .exitTapped,
        .roundLoaded(DrillRound(size: 0, cards: [])),
        .roundLoadFailed("boom"),
        .verdictReceived(makeVerdict(judged: true)),
        .attemptFailed("boom"),
        .appealResolved(makeAppealOutcome()),
    ]

    for action in entrances {
        #expect(action.roundEvent != nil, "\(action) 没有对应事件 —— 屏幕发了它什么也不会发生")
    }
    #expect(DrillAction.applyRound(DrillRoundState(), sourceSessionID: nil).roundEvent == nil)
}

// MARK: - reducer

/// reducer 只做一件事：把机器算完的结果收下。它不自己算状态 —— 算状态要发效应。
@Test func theReducerOnlyTakesTheMachineOutputIn() {
    var round = DrillRoundState()
    round.phase = .settled
    var state = DrillState()

    drillReducer(&state, .applyRound(round, sourceSessionID: "s-7"))

    #expect(state.round == round)
    #expect(state.sourceSessionID == "s-7")
}

// MARK: - 中间件：一整轮

/// 一轮完整的闪测，走真实的中间件路径（取题 → 读数 → 作答 → 判定 → 申诉）。
///
/// 用真实的 `AppStoreFactory` 而不是 `TestStore`：这一轮的价值全在**效应有没有真的发出去**
/// （取题带了几题、判定带了几毫秒、申诉带的是哪个 record），而纯 reducer 判据看不到它们。
@MainActor
@Test func aWholeRoundGoesThroughTheRealMiddleware() async throws {
    let client = RecordingDrillClient(
        round: DrillRound(
            size: 1,
            cards: [DrillCard(blockID: "b1", intentZH: "说明下一步", expressionEN: "I'll do it tomorrow.")]
        )
    )
    let store = try makeDrillStore(client: client, policy: .drillTest)

    store.dispatch(.drill(.startTapped(size: 1, sessionID: "s-7")))

    try await waitUntil { store.state.drill.phase == .ready }
    // 读数窗口自己走完（0.05s），不需要屏幕来推。
    try await waitUntil { store.state.drill.phase == .answering }

    // 到点：机器带**截止时长**提交，而不是等判定回来才知道花了几毫秒。
    store.dispatch(.drill(.answerDeadlineReached))
    try await waitUntil { store.state.drill.phase == .verdict }

    let judged = try #require(await client.judgeCalls.first)
    #expect(judged.blockID == "b1")
    #expect(judged.asrText == "", "超时提交不该编出一句话")
    #expect(
        judged.responseMS == 30_000,
        "提交的用时不是策略里的截止时长（30s）：\(judged.responseMS)"
    )
    #expect(
        judged.sessionID == "s-7",
        "闪测是从哪次练习会话打开的，判定时要带上：\(judged.sessionID ?? "nil")"
    )
    #expect(store.state.drill.recognitionText == "我明天做")

    // 申诉：带的是判定给的那个 record。
    let recordID = try #require(store.state.drill.lastVerdict?.recordID)
    store.dispatch(.drill(.appealTapped))
    try await waitUntil { store.state.drill.lastAppeal != nil }
    #expect(await client.appealCalls == [recordID])

    // 收尾。
    store.dispatch(.drill(.advanceTapped))
    #expect(store.state.drill.phase == .settled)
    #expect(store.state.drill.isSettled)
}

/// 顺序：如果只有一张卡，先进 `.verdict`，点「下一题」才结算。
@MainActor
@Test func theRoundSettlesOnlyAfterTheLastCardAdvances() async throws {
    let client = RecordingDrillClient(
        round: DrillRound(
            size: 2,
            cards: [
                DrillCard(blockID: "b1", intentZH: "一", expressionEN: "one"),
                DrillCard(blockID: "b2", intentZH: "二", expressionEN: "two"),
            ]
        )
    )
    let store = try makeDrillStore(client: client, policy: .drillTest)

    store.dispatch(.drill(.startTapped(size: 2, sessionID: nil)))
    try await waitUntil { store.state.drill.phase == .answering }
    store.dispatch(.drill(.answerCaptured(asrText: "one", at: Date())))
    try await waitUntil { store.state.drill.phase == .verdict }
    #expect(store.state.drill.current?.blockID == "b1")
    #expect(store.state.drill.planned == 2)

    store.dispatch(.drill(.advanceTapped))
    #expect(store.state.drill.phase == .ready)
    #expect(store.state.drill.position == 2)
    #expect(store.state.drill.current?.blockID == "b2")

    try await waitUntil { store.state.drill.phase == .answering }
    store.dispatch(.drill(.answerCaptured(asrText: "two", at: Date())))
    try await waitUntil { store.state.drill.phase == .verdict }

    store.dispatch(.drill(.advanceTapped))
    #expect(store.state.drill.phase == .settled)
    #expect(await client.judgeCalls.count == 2)
}

/// 取题失败要落在 `.failed` 上，而且**消息要带着**——否则屏幕只能显示「出错了」。
@MainActor
@Test func aFailedFetchFailsTheRoundWithItsMessage() async throws {
    let client = RecordingDrillClient(round: nil)
    await client.setFailLoad(true)
    let store = try makeDrillStore(client: client, policy: .drillTest)

    store.dispatch(.drill(.startTapped(size: 10, sessionID: nil)))

    try await waitUntil {
        if case .failed = store.state.drill.phase { return true }
        return false
    }
    let message = try #require(store.state.drill.failureMessage)
    #expect(!message.isEmpty, "失败态没有带着消息 —— 屏幕只能显示「出错了」")
    // ⚠️ 2026-10-02 改：这条判据此前钉的是「消息等于 `localizedDescription`」。
    // 那正是**错的那一半**——`localizedDescription` 是给开发看的字符串，
    // 而 屏 05 是给学员看的（截图里抓到过一句 `TokenError error 0.`）。
    // 所以现在钉的是反面：**不能**是原来那句。
    #expect(message != "boom", "把 localizedDescription 端到屏幕上了")
}

/// 空轮（没有到期的卡）不是错误：它是 `.empty`，屏幕可以说「今天没有要复习的」。
@MainActor
@Test func anEmptyRoundIsNotAFailure() async throws {
    let client = RecordingDrillClient(round: DrillRound(size: 0, cards: []))
    let store = try makeDrillStore(client: client, policy: .drillTest)

    store.dispatch(.drill(.startTapped(size: 10, sessionID: nil)))

    try await waitUntil { store.state.drill.phase == .empty }
    #expect(store.state.drill.failureMessage == nil)
}

/// 离开这一轮时，**还在飞的东西要停**。
///
/// 判据看的是「客户端有没有被取消」而不是状态：机器对 `.roundLoaded` 有相位守卫
/// （只在 `.loading` 收），所以「晚到的取题结果」本来就进不来 —— 取消要证明的是
/// 「那次请求真的停了」，否则学员退出后手机上还在跑一次注定被丢掉的三题请求。
@MainActor
@Test func leavingTheRoundCancelsWhatIsStillInFlight() async throws {
    let client = RecordingDrillClient(round: nil)
    await client.setSlowLoad(true)
    let store = try makeDrillStore(client: client, policy: .drillTest)

    store.dispatch(.drill(.startTapped(size: 10, sessionID: nil)))
    try await waitUntil { await client.roundSizes == [10] }

    store.dispatch(.drill(.exitTapped))
    #expect(store.state.drill.phase == .idle)

    try await waitUntil(timeoutNanoseconds: 3_000_000_000) { await client.loadWasCancelled }
}

// MARK: - 装置

private extension DrillRoundPolicy {
    /// 读数窗口压到 50ms（真实是 1s）；作答截止放到 30s，好让**测试自己**决定什么时候到点 ——
    /// 否则「到点提交」这条判据会变成一条计时赛跑。
    static let drillTest = DrillRoundPolicy(
        roundSize: 10,
        readinessSeconds: 0.05,
        answerSeconds: 30,
        maxRequeuesPerCard: 1
    )
}

@MainActor
private func makeDrillStore(
    client: RecordingDrillClient,
    policy: DrillRoundPolicy
) throws -> AppStore {
    let container = Container()
    container.reset()
    container.drillClient.register { client }

    var initial = AppState.initial
    initial.drill = DrillState(round: DrillRoundState(policy: policy))
    return AppStoreFactory.make(container: container, initialState: initial)
}

private func makeVerdict(
    pass: Bool = true,
    judged: Bool,
    asrText: String = "我明天做"
) -> DrillVerdict {
    DrillVerdict(
        pass: pass,
        judgeReason: pass ? "equivalent" : "not equivalent",
        judged: judged,
        retryable: !judged,
        successStreak: pass ? 1 : 0,
        state: pass ? .automated : .training,
        nextDueAt: Date(timeIntervalSince1970: 1_800_000_000),
        recorded: judged,
        recordID: judged ? 42 : 0,
        promoted: pass,
        asrText: asrText
    )
}

private func makeAppealOutcome(restored: Bool = true) -> DrillAppealOutcome {
    DrillAppealOutcome(
        recordID: 42,
        blockID: "b1",
        restored: restored,
        alreadyAppealed: false,
        state: restored ? .automated : .training,
        successStreak: 1,
        nextDueAt: Date(timeIntervalSince1970: 1_800_000_000),
        note: nil
    )
}

/// 记录型的闪测替身。
///
/// 判定与申诉都返回成功，好让「一轮能走完」这条判据只关心顺序与传参；失败路径由
/// `setFailLoad` 单独开。
private actor RecordingDrillClient: DrillClient {
    struct JudgeCall: Equatable, Sendable {
        let blockID: String
        let asrText: String
        let responseMS: Int
        let sessionID: String?
    }

    private let round: DrillRound?
    private var failLoad = false
    private var slowLoad = false

    private(set) var roundSizes: [Int] = []
    private(set) var judgeCalls: [JudgeCall] = []
    private(set) var appealCalls: [Int64] = []
    private(set) var loadWasCancelled = false

    init(round: DrillRound?) {
        self.round = round
    }

    func setFailLoad(_ value: Bool) { failLoad = value }
    func setSlowLoad(_ value: Bool) { slowLoad = value }

    func dueRound(size: Int) async throws -> DrillRound {
        roundSizes.append(size)
        if slowLoad {
            do {
                try await Task.sleep(for: .milliseconds(400))
            } catch {
                loadWasCancelled = true
                throw error
            }
        }
        if failLoad { throw DrillStubError.load }
        return round ?? DrillRound(size: 0, cards: [])
    }

    func judge(
        blockID: String,
        asrText: String,
        responseMS: Int,
        sessionID: String?
    ) async throws -> DrillVerdict {
        judgeCalls.append(
            JudgeCall(blockID: blockID, asrText: asrText, responseMS: responseMS, sessionID: sessionID)
        )
        return makeVerdict(judged: true)
    }

    func appeal(recordID: Int64) async throws -> DrillAppealOutcome {
        appealCalls.append(recordID)
        return makeAppealOutcome()
    }
}

private enum DrillStubError: LocalizedError {
    case load

    var errorDescription: String? { "boom" }
}
