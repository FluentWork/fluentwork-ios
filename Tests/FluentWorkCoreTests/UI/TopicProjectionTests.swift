import FluentWorkCore
import FluentWorkNetworking
import Foundation
import Testing

@testable import FluentWorkUI

/// `TopicCardsViewModel.make(from:)` —— 话题建议屏的投影（H1 列表 / H2 来源 / H3 打卡草稿）。
///
/// 这一屏的 state 是这一批里最厚的一份：`visibleCards` / `canCheckIn` / `canDismiss` /
/// `usedBlockIDs` / `streakDays` / `checkingInCardIDs` 全是给屏幕准备的。**少读任何一个都不会有
/// 东西报错** —— 所以一条条都点名断言。
@Suite("话题卡的投影")
struct TopicProjectionTests {

    // MARK: - fixture

    private func card(
        id: String = "c1",
        title: String = "向下周的 standup 同步缓存方案进展",
        promptEN: String = "Quick update on the caching work —",
        promptZH: String = "快速同步一下缓存这块的进展",
        cardType: TopicCardType = .practice,
        blockIDs: [String] = ["b1", "b2"],
        blocks: [TopicBlockRef] = [
            TopicBlockRef(id: "b1", expressionEN: "I'll wrap it up next week.", intentZH: "说进度"),
            TopicBlockRef(id: "b2", expressionEN: "Let's align on the timeline.", intentZH: "对齐排期"),
        ],
        sourceNote: String? = "你在 9/24 练过这个方向",
        checkedInAt: Date? = nil,
        dismissedAt: Date? = nil
    ) -> TopicCard {
        TopicCard(
            id: id,
            forDate: Date(timeIntervalSince1970: 1_774_000_000),
            title: title,
            promptEN: promptEN,
            promptZH: promptZH,
            cardType: cardType,
            seedTags: ["cache"],
            blockIDs: blockIDs,
            blocks: blocks,
            sourceNote: sourceNote,
            validUntil: Date(timeIntervalSince1970: 1_774_600_000),
            checkedInAt: checkedInAt,
            dismissedAt: dismissedAt,
            dismissReason: nil,
            createdAt: Date(timeIntervalSince1970: 1_774_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_774_000_000)
        )
    }

    private func state(_ cards: [TopicCard], phase: TopicPhase = .ready) -> TopicState {
        var state = TopicState()
        state.phase = phase
        state.cards = cards
        return state
    }

    // MARK: - P1 相位

    /// 五个相位一一对应，其中 **`.empty` 不许折成 `.failed`**：
    /// 服务端明说 `GET /topic-cards` 在生成之前可能是空的，那是「今天还没到点」，不是出错。
    @Test func 五个相位一一对应() {
        let expected: [(TopicPhase, TopicViewPhase)] = [
            (.idle, .idle),
            (.loading, .loading),
            (.ready, .ready),
            (.empty, .empty),
            (.failed, .failed),
        ]

        for (domain, view) in expected {
            #expect(TopicCardsViewModel.make(from: state([], phase: domain)).phase == view)
        }
        #expect(TopicCardsViewModel.make(from: state([], phase: .empty)).showsRetryAction == false)
        #expect(TopicCardsViewModel.make(from: state([], phase: .failed)).showsRetryAction)
    }

    // MARK: - P2 行来自哪一份

    /// **行来自 `visibleCards`，不是 `cards`。**
    ///
    /// 「忽略」这个动作的全部意义就是让卡离开列表。读原始列表的话，忽略按下去之后卡还在
    /// （只多一个 `isDismissed` 标记），而屏幕上没有任何东西提示它已经作废。
    @Test func 行来自忽略之后的那一份() {
        let cards = [
            card(id: "kept"),
            card(id: "dismissed", dismissedAt: Date(timeIntervalSince1970: 1_774_100_000)),
        ]

        let model = TopicCardsViewModel.make(from: state(cards))

        #expect(model.cards.map(\.id) == ["kept"], "已忽略的卡没有离开列表")
        // 原始列表不动 —— 是投影把它挡住了。
        #expect(cards.count == 2)
    }

    // MARK: - P2 每个维度都有人读

    /// 每张卡转发每一个维度，**且 fixture 用的是非默认值**。
    ///
    /// 用默认值的话「忘了转发」与「转发对了」同值 —— 这条判据就替错误签了字。
    @Test func 每张卡转发每一个维度() {
        var s = state([card(id: "c1", checkedInAt: nil)])
        s.checkinDrafts["c1"] = TopicCheckinDraft(
            reflection: "今天在评审里用上了",
            selectedBlockIDs: ["b2"]
        )
        s.checkingInCardIDs = ["c1"]
        s.lastCheckin = TopicCheckinResult(checkinID: "k1", streakDays: 6, recordedUse: 1)
        s.actionErrorMessage = "打卡失败"

        let model = TopicCardsViewModel.make(from: s)
        let row = model.cards[0]

        #expect(row.id == "c1")
        #expect(row.title == "向下周的 standup 同步缓存方案进展")
        #expect(row.promptEN == "Quick update on the caching work —")
        #expect(row.promptZH == "快速同步一下缓存这块的进展")
        #expect(row.sourceNote == "你在 9/24 练过这个方向")
        #expect(row.blocks.map(\.id) == ["b1", "b2"])
        #expect(row.reflection == "今天在评审里用上了")
        #expect(row.canDiscardDraft, "有草稿却清不了")
        // 勾选是**按草稿**算的：勾了 b2，所以 b1 不选中、b2 选中。
        #expect(row.blocks.map(\.isSelected) == [false, true])
        // 在飞 → 不能重复提交，但**不影响其它事实**。
        #expect(row.isCheckingIn)
        #expect(row.canCheckIn == false, "请求在飞时还能再点一次")

        #expect(model.checkedInCount == 0, "这张卡还没打卡")
        #expect(model.streakDays == 6)
        #expect(model.actionErrorMessage == "打卡失败")
    }

    /// 已打卡的卡：留着（`checkedInCount` 要能解释它），但两个动作都不能再点。
    ///
    /// ⚠️ 这条判据第一次跑是**红的**，而红的是期望不是实现：`TopicState.canDismiss` 刻意不看
    /// `isCheckedIn`（服务端 `Service.Dismiss` 也真的不检查打卡状态），所以 state 的回答是
    /// 「可以忽略」。但屏幕上说不出这个道理 —— 一张刚说过「已和真人聊过」的卡上再挂一个
    /// 「今天聊不到」，是两个自相矛盾的入口。**规则因此加在投影这一层**（见 `TopicProjection`
    /// 里那句话），判据守的就是这一层。
    @Test func 已打卡的卡留在列表里但不能再点() {
        let s = state([card(id: "done", checkedInAt: Date(timeIntervalSince1970: 1_774_100_000))])

        let model = TopicCardsViewModel.make(from: s)
        let row = model.cards[0]

        #expect(model.cards.count == 1, "打完卡它就从列表里消失了 —— 连胜天数就无从解释")
        #expect(row.isCheckedIn)
        #expect(model.checkedInCount == 1)
        #expect(row.canCheckIn == false, "打过卡再点一次服务端会回 409")
        #expect(row.canDismiss == false, "刚聊过的卡上不该再出现「今天聊不到」")
    }

    /// 上面那条的**反向**：还没打卡的卡，忽略仍然是可点的。
    ///
    /// 少了这一半，「`canDismiss` 恒为 false」也能让上一条通过。
    @Test func 还没打卡的卡可以忽略() {
        let s = state([card(id: "todo")])

        let row = TopicCardsViewModel.make(from: s).cards[0]

        #expect(row.isCheckedIn == false)
        #expect(row.canDismiss, "还没聊过的卡忽略不了")
    }

    /// **三个事实各自独立**：一张卡的「在飞」不许传染给另一张。
    @Test func 在飞与能不能点各自独立() {
        var s = state([card(id: "a"), card(id: "b")])
        s.checkingInCardIDs = ["a"]
        s.dismissingCardIDs = ["b"]

        let rows = TopicCardsViewModel.make(from: s).cards

        #expect(rows[0].isCheckingIn)
        #expect(rows[0].isDismissing == false)
        #expect(rows[0].canDismiss, "在飞的那张卡不该连忽略也点不动")
        #expect(rows[1].isDismissing)
        #expect(rows[1].isCheckingIn == false)
        #expect(rows[1].canCheckIn, "忽略在飞不该影响打卡")
    }

    /// 草稿只在**有东西可清**时才让「清空」出现。
    ///
    /// 打字再删光之后草稿那条记录仍然在（`checkinDrafts[id] != nil`），而那时「清空」无事可做。
    @Test func 清空只在有东西可清时出现() {
        var s = state([card(id: "c1")])
        s.checkinDrafts["c1"] = TopicCheckinDraft()

        #expect(TopicCardsViewModel.make(from: s).cards[0].canDiscardDraft == false)

        s.checkinDrafts["c1"] = TopicCheckinDraft(reflection: "写了点东西")
        #expect(TopicCardsViewModel.make(from: s).cards[0].canDiscardDraft)

        s.checkinDrafts["c1"] = TopicCheckinDraft(selectedBlockIDs: ["b1"])
        #expect(TopicCardsViewModel.make(from: s).cards[0].canDiscardDraft, "只勾了块也算有东西可清")
    }

    // MARK: - H2 的来源标注

    /// **`nil` 的来源标注原样传下去**，不许在投影里被折成一句泛泛的话。
    ///
    /// 「一张没有 `source_note` 的卡，就是服务端没能把它落到你的语料上」—— 那是 H2 要看的信号。
    /// 补一句「来自你的练习」会把这个信号抹掉，而且抹得看不出来。
    @Test func 没有来源标注就保持没有() {
        let model = TopicCardsViewModel.make(from: state([card(id: "no-source", sourceNote: nil)]))

        #expect(model.cards[0].sourceNote == nil)
        // 有来源的那张不受影响 —— 否则「都变成 nil」也能过。
        #expect(
            TopicCardsViewModel.make(from: state([card(id: "has-source")]))
                .cards[0].sourceNote == "你在 9/24 练过这个方向"
        )
    }

    // MARK: - 两种错误分开

    /// 「这次动作没成」与「这一屏没有内容」是两件事，投影不许把它们合成一个字段。
    @Test func 整屏失败与单次动作失败分开() {
        var s = state([], phase: .failed)
        s.lastErrorMessage = "网络不可达"
        s.actionErrorMessage = "打卡没送上去"

        let model = TopicCardsViewModel.make(from: s)

        #expect(model.lastErrorMessage == "网络不可达")
        #expect(model.actionErrorMessage == "打卡没送上去")
    }
}

/// 忽略理由的四句中文（H3 / 86_ M11）。
///
/// 它们是**可数信号**的呈现：四种「最后一公里断了」各自指向一个不同的修法，
/// 所以四句必须互相区分得开 —— 写成近义词等于让那个信号白收。
@Suite("忽略理由的文案")
struct TopicDismissReasonCopyTests {

    /// 四个理由一个不少，且**四句两两不同、都不为空**。
    @Test func 四个理由各有各的说法() {
        let labels = TopicDismissReason.allCases.map(\.label)

        #expect(TopicDismissReason.allCases.count == 4)
        #expect(labels.allSatisfy { !$0.isEmpty })
        #expect(Set(labels).count == 4, "有两个理由用了同一句话 —— 那个信号就分不开了")
        #expect(labels == ["没人可聊", "不敢开口", "没时间", "话题没用"])
    }
}
