import FactoryKit
import FluentWorkNetworking
import Foundation
import Testing
@testable import FluentWorkCore

// MARK: - 自评文本的上限：字节，不是字符

/// **500 是字节不是字符**，而这两个数在中文上差三倍。
///
/// 服务端 `internal/topic/service.go:187-189` 用 `len(reflection) > MaxReflectionLen` ——
/// Go 的 `len()` 数**字节**，而且超限返回 **400**（不是截断）。OpenAPI 那边写的是
/// `maxLength: 500`，JSON Schema 里那是**字符**。按字符截的客户端会撞 400：
/// 500 个汉字是 1500 字节。
@Test func reflectionIsCappedByBytesNotCharacters() {
    let tooLong = String(repeating: "字", count: 200)  // 600 字节
    let capped = TopicReflection.capped(tooLong)

    #expect(capped.utf8.count <= TopicReflection.maxBytes, "截完还是 \(capped.utf8.count) 字节")
    #expect(capped.count == 166, "500 / 3 = 166 个汉字：实际 \(capped.count)")
    #expect(
        !capped.unicodeScalars.contains { $0.value == 0xFFFD },
        "切出了半个码点 —— 学员会看到一串替换符"
    )
}

/// 没超限的自评**一个字都不动**：那是学员自己写的话，除了长度以外不该被碰。
@Test func aShortReflectionIsLeftExactlyAsWritten() {
    let written = "  今天用了两句，还行。 "  // 前后空格也保留
    #expect(TopicReflection.capped(written) == written)
    #expect(TopicReflection.capped("") == "")
}

/// 边界：正好 500 字节通过；501 字节才截。
@Test func theCapIsInclusive() {
    let exactly = String(repeating: "x", count: TopicReflection.maxBytes)
    #expect(TopicReflection.capped(exactly) == exactly)

    let oneOver = exactly + "x"
    #expect(TopicReflection.capped(oneOver).utf8.count == TopicReflection.maxBytes)
}

// MARK: - 列表的取舍（H1）

/// 忽略的卡离开列表；打过卡的**留着**。
///
/// 打完卡就消失的话，「今天三张都聊过了」和连胜天数就没有任何东西可解释 ——
/// 学员会以为卡丢了。
@Test func dismissedCardsLeaveTheListAndCheckedInOnesStay() {
    let dismissed = makeTopicCard(id: "c1", dismissedAt: Date(timeIntervalSince1970: 100))
    let checkedIn = makeTopicCard(id: "c2", checkedInAt: Date(timeIntervalSince1970: 200))
    let fresh = makeTopicCard(id: "c3")
    let state = TopicState(phase: .ready, cards: [dismissed, checkedIn, fresh])

    #expect(state.visibleCards.map(\.id) == ["c2", "c3"])
    #expect(state.checkedInCount == 1)
    #expect(state.cards.count == 3, "产出本身不该被改写")
}

/// 「能不能用」与「有没有这个控件」是两件事 —— 视图读的是前者。
@Test func usabilityIsNotExistence() {
    let open = makeTopicCard(id: "c1", blockIDs: ["b1"])
    let done = makeTopicCard(id: "c2", checkedInAt: Date())
    let gone = makeTopicCard(id: "c3", dismissedAt: Date())
    var state = TopicState(phase: .ready, cards: [open, done, gone])

    #expect(state.canCheckIn("c1"))
    #expect(!state.canCheckIn("c2"), "已经打过卡了 —— 再点一次服务端只会回 409")
    #expect(!state.canDismiss("c3"))
    #expect(!state.canCheckIn("不存在的卡"))

    // 在飞的时候两个都不许再点。
    state.checkingInCardIDs = ["c1"]
    #expect(!state.canCheckIn("c1"))
}

/// 送上去的 `used_block_ids` = 勾选 ∩ 这张卡提供过的，**且按卡自己的顺序**。
///
/// 顺序不是形式问题：同一份勾选发送两次必须逐字相同，否则服务端的日志与去重都读不出规律。
@Test func usedBlockIDsIsTheIntersectionInTheCardsOwnOrder() {
    let card = makeTopicCard(id: "c1", blockIDs: ["b1", "b2", "b3"])
    var state = TopicState(phase: .ready, cards: [card])

    state.checkinDrafts["c1"] = TopicCheckinDraft(
        selectedBlockIDs: ["b3", "b1", "从没提供过的块"]
    )

    #expect(state.usedBlockIDs(for: "c1") == ["b1", "b3"])
}

/// 勾一条这张卡没提供过的块：**进不了草稿**。
///
/// 放它进来界面会显示一条勾着的幽灵项，而服务端只会把它当「客户端有 bug」报回来
/// （`ignored_block_ids` 就是为这个存在的）。清在源头。
@Test func tickingABlockTheCardNeverOfferedDoesNotStick() {
    let card = makeTopicCard(id: "c1", blockIDs: ["b1"])
    var state = TopicState(phase: .ready, cards: [card])

    topicReducer(&state, .checkinDraftBlockToggled(cardID: "c1", blockID: "幽灵块"))

    #expect(state.draft(for: "c1").selectedBlockIDs.isEmpty)
    #expect(state.usedBlockIDs(for: "c1").isEmpty)
}

/// 逐字段：勾选是**切换**，自评是**替换**，而且换一张卡不影响另一张。
@Test func draftsArePerCard() {
    let a = makeTopicCard(id: "a", blockIDs: ["b1"])
    let b = makeTopicCard(id: "b", blockIDs: ["b2"])
    var state = TopicState(phase: .ready, cards: [a, b])

    topicReducer(&state, .checkinDraftBlockToggled(cardID: "a", blockID: "b1"))
    topicReducer(&state, .checkinDraftReflectionChanged(cardID: "b", value: "两张卡各说各的"))

    #expect(state.draft(for: "a").selectedBlockIDs == ["b1"])
    #expect(state.draft(for: "a").reflection.isEmpty)
    #expect(state.draft(for: "b").selectedBlockIDs.isEmpty)
    #expect(state.draft(for: "b").reflection == "两张卡各说各的")
}

/// 新一版产出里没有的卡，它的草稿与在途标记都要剪掉。
///
/// 卡 id 留着一个幽灵名，下一次撞上同 id 的卡就会带着**别人的**勾选出现。
@Test func aNewListPrunesDraftsAndInFlightToWhatIsStillThere() {
    var state = TopicState(phase: .ready, cards: [makeTopicCard(id: "old")])
    state.checkinDrafts["old"] = TopicCheckinDraft(reflection: "旧卡的字")
    state.checkinDrafts["幽灵"] = TopicCheckinDraft(reflection: "已经不存在的卡")
    state.checkingInCardIDs = ["old", "幽灵"]

    topicReducer(&state, .cardsLoaded([makeTopicCard(id: "new")]))

    #expect(state.checkinDrafts.isEmpty)
    #expect(state.checkingInCardIDs.isEmpty)
}

/// 空列表是 `.empty`，**不是失败**：`GET /topic-cards` 自己写着「possibly empty before
/// generation」—— 今天还没到生成的时候，屏上该说「今天还没有话题」。
@Test func anEmptyListIsEmptyNotFailed() {
    var state = TopicState()
    topicReducer(&state, .cardsLoaded([]))

    #expect(state.phase == .empty)
    #expect(state.lastErrorMessage == nil)
}

// MARK: - 解码的宽容（只宽容该宽容的）

/// 认不出的 `card_type` 不许把**整条列表**弄失败：话题卡是「今天的三张」，
/// 一张的类型读不出来不该吞掉另外两张。
@Test func anUnknownCardTypeDoesNotKillTheWholeList() throws {
    let cards = try decodeCards(
        """
        [
          {"id":"c1","for_date":"2026-09-30T00:00:00Z","title":"t1","prompt_en":"Look…","prompt_zh":"聊…",
           "card_type":"mixer","seed_tags":[],"block_ids":[],"valid_until":"2026-10-01T00:00:00Z",
           "created_at":"2026-09-30T00:00:00Z","updated_at":"2026-09-30T00:00:00Z"},
          {"id":"c2","for_date":"2026-09-30T00:00:00Z","title":"t2","prompt_en":"Ask…","prompt_zh":"问…",
           "card_type":"practice","seed_tags":[],"block_ids":[],"valid_until":"2026-10-01T00:00:00Z",
           "created_at":"2026-09-30T00:00:00Z","updated_at":"2026-09-30T00:00:00Z"}
        ]
        """
    )

    #expect(cards.count == 2)
    #expect(cards[0].cardType == .unknown)
    #expect(cards[1].cardType == .practice)
}

/// 认不出的 `dismiss_reason` ⇒ **原因为 nil，卡还在**。
///
/// 「已忽略」的事实是 `dismissed_at`，原因是附加说明。服务端将来加第五个理由时，
/// 让一张卡从列表里消失远比「显示成已忽略、但没有原因」更糟。
@Test func anUnknownDismissReasonCostsTheReasonNotTheCard() throws {
    let cards = try decodeCards(
        """
        [
          {"id":"c1","for_date":"2026-09-30T00:00:00Z","title":"t","prompt_en":"Look…","prompt_zh":"聊…",
           "card_type":"practice","seed_tags":[],"block_ids":[],"valid_until":"2026-10-01T00:00:00Z",
           "dismissed_at":"2026-09-30T09:00:00Z","dismiss_reason":"too_long",
           "created_at":"2026-09-30T00:00:00Z","updated_at":"2026-09-30T00:00:00Z"}
        ]
        """
    )

    #expect(cards.count == 1)
    #expect(cards[0].isDismissed, "忽略的事实丢了")
    #expect(cards[0].dismissReason == nil, "认不出的原因被硬塞成了某个已知值")
}

/// 省略 `blocks` / `source_note` 都不许崩，**而且不许替 `source_note` 编一句**。
///
/// H2 就是要看这一栏：没有来源标注 = 这张卡没被落到学员的语料上（`model.go:56-58`）。
/// 填个默认值等于把这个信号抹掉。
@Test func aMissingSourceNoteStaysMissing() throws {
    let cards = try decodeCards(
        """
        [
          {"id":"c1","for_date":"2026-09-30T00:00:00Z","title":"t","prompt_en":"Look…","prompt_zh":"聊…",
           "card_type":"warmup","seed_tags":[],"block_ids":["b1"],"valid_until":"2026-10-01T00:00:00Z",
           "created_at":"2026-09-30T00:00:00Z","updated_at":"2026-09-30T00:00:00Z"}
        ]
        """
    )

    #expect(cards[0].sourceNote == nil)
    #expect(cards[0].blocks.isEmpty, "省略的 blocks 该是空数组，不是缺数据")
    #expect(cards[0].blockIDs == ["b1"])
}

// MARK: - 中间件：一整条路

/// 进屏就取卡与统计，两条路互不依赖。
@MainActor
@Test func appearingLoadsCardsAndStats() async throws {
    let client = RecordingTopicClient(cards: [makeTopicCard(id: "c1", blockIDs: ["b1"])])
    let store = try makeTopicStore(client: client)

    store.dispatch(.topic(.appear))

    try await waitUntil { store.state.topic.phase == .ready }
    #expect(store.state.topic.visibleCards.map(\.id) == ["c1"])
    #expect(await client.cardCalls == 1)
    #expect(store.state.topic.stats?.checkins == 3)
}

/// 打卡送的是**勾过的那几条**（按卡自己的顺序）+ 学员写的自评，一次请求带全。
@MainActor
@Test func checkingInSendsTheReflectionAndTheTickedBlocks() async throws {
    let client = RecordingTopicClient(
        cards: [makeTopicCard(id: "c1", blockIDs: ["b1", "b2", "b3"])]
    )
    let store = try makeTopicStore(client: client)

    store.dispatch(.topic(.appear))
    try await waitUntil { store.state.topic.phase == .ready }

    store.dispatch(.topic(.checkinDraftReflectionChanged(cardID: "c1", value: "今天用了头两句")))
    store.dispatch(.topic(.checkinDraftBlockToggled(cardID: "c1", blockID: "b2")))
    store.dispatch(.topic(.checkinDraftBlockToggled(cardID: "c1", blockID: "b1")))
    store.dispatch(.topic(.checkinTapped(cardID: "c1")))

    try await waitUntil { await client.checkinCalls.count == 1 }
    let call = try #require(await client.checkinCalls.first)
    #expect(call.cardID == "c1")
    #expect(call.reflection == "今天用了头两句")
    #expect(call.usedBlockIDs == ["b1", "b2"], "顺序该是卡自己的顺序：\(call.usedBlockIDs)")
}

/// 打卡成功之后卡要变成「已打卡」，连胜与「真的用掉几条」都要落到状态里。
@MainActor
@Test func aSuccessfulCheckinMarksTheCardAndRecordsTheStreak() async throws {
    let client = RecordingTopicClient(cards: [makeTopicCard(id: "c1", blockIDs: ["b1"])])
    let store = try makeTopicStore(client: client)

    store.dispatch(.topic(.appear))
    try await waitUntil { store.state.topic.phase == .ready }
    store.dispatch(.topic(.checkinTapped(cardID: "c1")))

    try await waitUntil { store.state.topic.card(for: "c1")?.isCheckedIn == true }
    #expect(store.state.topic.streakDays == 4)
    #expect(store.state.topic.lastCheckin?.recordedUse == 1)
    #expect(store.state.topic.checkinDrafts.isEmpty, "打完卡草稿该清掉")
    #expect(store.state.topic.visibleCards.count == 1, "打过卡的卡要留在列表里")
}

/// 打过卡的卡**不许再发一次请求**：服务端对重复打卡回 409，那一次往返注定失败。
@MainActor
@Test func aCheckedInCardIsNeverSentTwice() async throws {
    let client = RecordingTopicClient(cards: [makeTopicCard(id: "c1", blockIDs: [])])
    let store = try makeTopicStore(client: client)

    store.dispatch(.topic(.appear))
    try await waitUntil { store.state.topic.phase == .ready }
    store.dispatch(.topic(.checkinTapped(cardID: "c1")))
    try await waitUntil { store.state.topic.card(for: "c1")?.isCheckedIn == true }

    store.dispatch(.topic(.checkinTapped(cardID: "c1")))
    try await Task.sleep(for: .milliseconds(120))

    #expect(await client.checkinCalls.count == 1, "第二次点击又发了一遍")
    #expect(!store.state.topic.canCheckIn("c1"))
}

/// 打卡失败：原因是带上来了，**而学员写的字一个字都不能丢**。
@MainActor
@Test func aFailedCheckinKeepsTheDraft() async throws {
    let client = RecordingTopicClient(cards: [makeTopicCard(id: "c1", blockIDs: ["b1"])])
    await client.setFailCheckin(true)
    let store = try makeTopicStore(client: client)

    store.dispatch(.topic(.appear))
    try await waitUntil { store.state.topic.phase == .ready }
    store.dispatch(.topic(.checkinDraftReflectionChanged(cardID: "c1", value: "写了很久的一段话")))
    store.dispatch(.topic(.checkinDraftBlockToggled(cardID: "c1", blockID: "b1")))
    store.dispatch(.topic(.checkinTapped(cardID: "c1")))

    try await waitUntil { store.state.topic.actionErrorMessage != nil }
    #expect(store.state.topic.draft(for: "c1").reflection == "写了很久的一段话")
    #expect(store.state.topic.draft(for: "c1").selectedBlockIDs == ["b1"])
    #expect(store.state.topic.card(for: "c1")?.isCheckedIn == false)
    #expect(store.state.topic.canCheckIn("c1"), "失败之后该能重试")
}

/// 忽略：带上四选一的原因，卡离开列表。
@MainActor
@Test func dismissingSendsTheReasonAndTakesTheCardOut() async throws {
    let client = RecordingTopicClient(cards: [makeTopicCard(id: "c1")])
    let store = try makeTopicStore(client: client)

    store.dispatch(.topic(.appear))
    try await waitUntil { store.state.topic.phase == .ready }
    store.dispatch(.topic(.dismissTapped(cardID: "c1", reason: .noTime)))

    try await waitUntil { store.state.topic.visibleCards.isEmpty }
    #expect(await client.dismissCalls == [.init(cardID: "c1", reason: .noTime)])
    #expect(store.state.topic.card(for: "c1")?.dismissReason == .noTime)
    #expect(store.state.topic.phase == .ready, "全忽略掉了不等于今天没有卡")
}

/// **统计失败不该让整屏变成错误页**：它是附加信息，不是这一屏的内容。
@MainActor
@Test func aFailedStatsFetchDoesNotFailTheScreen() async throws {
    let client = RecordingTopicClient(cards: [makeTopicCard(id: "c1")])
    await client.setFailStats(true)
    let store = try makeTopicStore(client: client)

    store.dispatch(.topic(.appear))

    try await waitUntil { store.state.topic.phase == .ready }
    try await Task.sleep(for: .milliseconds(120))
    #expect(store.state.topic.stats == nil)
    #expect(store.state.topic.lastErrorMessage == nil, "没有统计就只是没有统计")
}

// MARK: - 装置

@MainActor
private func makeTopicStore(client: RecordingTopicClient) throws -> AppStore {
    let container = Container()
    container.reset()
    container.topicClient.register { client }
    return AppStoreFactory.make(container: container, initialState: AppState.initial)
}

private func decodeCards(_ json: String) throws -> [TopicCard] {
    try SessionHistoryJSON.makeDecoder().decode([TopicCard].self, from: Data(json.utf8))
}

private func makeTopicCard(
    id: String,
    blockIDs: [String] = [],
    sourceNote: String? = "来自素材《周会同步》",
    checkedInAt: Date? = nil,
    dismissedAt: Date? = nil
) -> TopicCard {
    let stamp = Date(timeIntervalSince1970: 1_800_000_000)
    return TopicCard(
        id: id,
        forDate: stamp,
        title: "同步缓存方案进展",
        promptEN: "I'll walk the team through the caching plan.",
        promptZH: "把缓存方案讲给团队听。",
        cardType: .practice,
        seedTags: ["standup"],
        blockIDs: blockIDs,
        blocks: blockIDs.map { TopicBlockRef(id: $0, expressionEN: "expr-\($0)", intentZH: "意图-\($0)") },
        sourceNote: sourceNote,
        validUntil: stamp.addingTimeInterval(86_400),
        checkedInAt: checkedInAt,
        dismissedAt: dismissedAt,
        dismissReason: nil,
        createdAt: stamp,
        updatedAt: stamp
    )
}

/// 记录型替身。
private actor RecordingTopicClient: TopicClient {
    struct CheckinCall: Equatable, Sendable {
        let cardID: String
        let reflection: String
        let usedBlockIDs: [String]
    }

    struct DismissCall: Equatable, Sendable {
        let cardID: String
        let reason: TopicDismissReason
    }

    private let cards: [TopicCard]
    private var failCheckin = false
    private var failStats = false

    private(set) var cardCalls = 0
    private(set) var checkinCalls: [CheckinCall] = []
    private(set) var dismissCalls: [DismissCall] = []

    init(cards: [TopicCard]) {
        self.cards = cards
    }

    func setFailCheckin(_ value: Bool) { failCheckin = value }
    func setFailStats(_ value: Bool) { failStats = value }

    func todayCards() async throws -> [TopicCard] {
        cardCalls += 1
        return cards
    }

    func checkin(
        cardID: String,
        reflection: String,
        usedBlockIDs: [String]
    ) async throws -> TopicCheckinResult {
        checkinCalls.append(
            CheckinCall(cardID: cardID, reflection: reflection, usedBlockIDs: usedBlockIDs)
        )
        if failCheckin { throw TopicStubError.boom }
        return TopicCheckinResult(checkinID: "ci-1", streakDays: 4, recordedUse: 1)
    }

    func stats(days: Int?) async throws -> TopicPracticeStats {
        if failStats { throw TopicStubError.boom }
        return TopicPracticeStats(
            windowDays: 7,
            checkins: 3,
            cardsServed: 9,
            blocksTotal: 20,
            blocksUsed: 6,
            greenBlocks: 4,
            greenUsed: 2,
            conversionRate: 0.3,
            checkinRate: 0.33,
            realUsesHit: 2,
            realUsesCheckin: 3,
            dismissReasons: [:],
            dismissRate: 0.1
        )
    }

    func dismiss(cardID: String, reason: TopicDismissReason) async throws -> TopicDismissResult {
        dismissCalls.append(DismissCall(cardID: cardID, reason: reason))
        return TopicDismissResult(cardID: cardID, reason: reason, alreadyDismissed: false)
    }
}

private enum TopicStubError: LocalizedError {
    case boom

    var errorDescription: String? { "boom" }
}
