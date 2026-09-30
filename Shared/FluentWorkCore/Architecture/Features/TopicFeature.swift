import FluentWorkNetworking
import Foundation
import TGReduxKit

/// 打卡自评文本的**字节**上限。
///
/// ⚠️ 这里的两个数不一样，而且差三倍，所以单独写成一个类型而不是散在各处：
///
/// - **服务端按 UTF-8 字节判**：`internal/topic/service.go:187-189` 是
///   `if len(reflection) > MaxReflectionLen`，Go 的 `len()` 数的是**字节**，
///   而且超限返回 **400**（不是截断）：`"reflection exceeds 500 bytes"`。
/// - **OpenAPI 写的是 `maxLength: 500`**，而 JSON Schema 里 `maxLength` 数的是**字符**。
///
/// 按字符截的客户端在中文上会撞 400：500 个汉字是 1500 字节。所以客户端按**字节**截，
/// 并且**在字符边界上**截 —— 从字节流的中间切一刀会切出半个码点，用户看到的是一串替换符。
public enum TopicReflection {
    public static let maxBytes = 500

    /// 截到 `maxBytes` 个 UTF-8 字节以内，且不切断任何字符。
    ///
    /// 不超限时**原样返回同一个字符串**（不做规范化、不 trim 用户打的空格）：
    /// 这一段是学员自己写的字，除了长度以外一个字都不该被动。
    public static func capped(_ text: String, maxBytes: Int = TopicReflection.maxBytes) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var out = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > maxBytes { break }
            out.append(character)
            used += size
        }
        return out
    }
}

public enum TopicPhase: String, Equatable, Sendable {
    case idle
    case loading
    case ready
    /// 服务端还没生成今天的卡（`GET /topic-cards` 明说「possibly empty before generation」）。
    ///
    /// **空不是失败**：它是「今天还没到生成的时候」，屏上该说「今天还没有话题」，不是「出错了」。
    case empty
    case failed
}

/// 一张卡的打卡草稿（H3）。
///
/// 草稿活在 store 里而不是视图里：`used_block_ids` 是这一轮唯一的**一手**证据
/// （`internal/topic/model.go:155-157`：练习有没有变成真实的开口，其它全是代理指标），
/// 而它由「勾了哪几条」叠加而成 —— 让这些勾选住在视图里，就没人能对它下判据。
public struct TopicCheckinDraft: Equatable, Sendable {
    public var reflection: String
    public var selectedBlockIDs: Set<String>

    public init(reflection: String = "", selectedBlockIDs: Set<String> = []) {
        self.reflection = reflection
        self.selectedBlockIDs = selectedBlockIDs
    }
}

public struct TopicState: Equatable, Sendable, State {
    public var phase: TopicPhase
    public var cards: [TopicCard]
    public var stats: TopicPracticeStats?
    public var checkinDrafts: [String: TopicCheckinDraft]
    public var checkingInCardIDs: Set<String>
    public var dismissingCardIDs: Set<String>
    /// 打卡/忽略失败的原因。**不写中文文案**：那是产品决定（见 R5-b 的先例），
    /// 这一层只把服务端/网络给的那句话带上来，UI 票决定怎么呈现。
    public var actionErrorMessage: String?
    public var lastErrorMessage: String?
    /// 最近一次打卡的结果 —— 连续天数（streak）与「真的用掉了几条」都从这里读。
    public var lastCheckin: TopicCheckinResult?

    public init(
        phase: TopicPhase = .idle,
        cards: [TopicCard] = [],
        stats: TopicPracticeStats? = nil,
        checkinDrafts: [String: TopicCheckinDraft] = [:],
        checkingInCardIDs: Set<String> = [],
        dismissingCardIDs: Set<String> = [],
        actionErrorMessage: String? = nil,
        lastErrorMessage: String? = nil,
        lastCheckin: TopicCheckinResult? = nil
    ) {
        self.phase = phase
        self.cards = cards
        self.stats = stats
        self.checkinDrafts = checkinDrafts
        self.checkingInCardIDs = checkingInCardIDs
        self.dismissingCardIDs = dismissingCardIDs
        self.actionErrorMessage = actionErrorMessage
        self.lastErrorMessage = lastErrorMessage
        self.lastCheckin = lastCheckin
    }

    // MARK: - 给视图读的投影

    /// 今天还在场的卡。**已忽略的不算** —— 忽略这个动作的全部意义就是让它离开列表。
    ///
    /// 已打卡的**留着**（带 `isCheckedIn`）：学员要看的是「今天三张都聊过了」，
    /// 而不是打完卡它们就凭空消失、连胜天数无从解释。
    public var visibleCards: [TopicCard] {
        cards.filter { !$0.isDismissed }
    }

    public var checkedInCount: Int {
        cards.filter(\.isCheckedIn).count
    }

    /// 连续打卡天数。只在这一次打卡之后有值 —— 服务端不给单独的 streak 查询。
    public var streakDays: Int? { lastCheckin?.streakDays }

    public func card(for cardID: String) -> TopicCard? {
        cards.first { $0.id == cardID }
    }

    public func draft(for cardID: String) -> TopicCheckinDraft {
        checkinDrafts[cardID] ?? TopicCheckinDraft()
    }

    /// 这张卡现在能不能打卡。
    ///
    /// 视图读这个，而不是读「有没有这个按钮」：**「有控件」不等于「控件能用」**。
    /// 打过卡再点一次服务端回 409，所以这里的假值是在替学员省一次注定失败的往返。
    public func canCheckIn(_ cardID: String) -> Bool {
        guard let card = card(for: cardID) else { return false }
        return !card.isCheckedIn && !checkingInCardIDs.contains(cardID)
    }

    /// 这张卡现在能不能忽略。
    ///
    /// 与 `canCheckIn` 分开：两者可以同时为真（还没打卡、也还没忽略），
    /// 但都不是「按钮存在」的意思。
    public func canDismiss(_ cardID: String) -> Bool {
        guard let card = card(for: cardID) else { return false }
        return !card.isDismissed && !dismissingCardIDs.contains(cardID)
    }

    /// 打卡要送上去的 `used_block_ids`：草稿里勾了的，**且这张卡确实提供过**的。
    ///
    /// 求交不是防御性代码：服务端会为「这张卡从没提供过的 id」回 `ignored_block_ids`
    /// （`TopicCheckinResult` 的说明就是为它写的），也就是**让服务端替客户端擦屁股**。
    /// 发出去之前先清掉，服务端那一列才有信号。
    public func usedBlockIDs(for cardID: String) -> [String] {
        guard let card = card(for: cardID) else { return [] }
        let selected = draft(for: cardID).selectedBlockIDs
        // 遍历**卡自己的清单**：交集是白拿的，顺序也是卡自己的顺序 ——
        // 同一份勾选发送两次会逐字相同，而 Set 的迭代顺序不保证这一点。
        return card.blockIDs.filter { selected.contains($0) }
    }
}

public enum TopicAction: Equatable, Sendable, Action {
    /// 进入话题卡屏（或它重新可见）。
    case appear
    case refreshRequested
    case cardsLoaded([TopicCard])
    case cardsFailed(String)
    case statsLoaded(TopicPracticeStats)

    case checkinDraftReflectionChanged(cardID: String, value: String)
    case checkinDraftBlockToggled(cardID: String, blockID: String)
    case checkinDraftDiscarded(cardID: String)
    case checkinTapped(cardID: String)
    case checkinSucceeded(cardID: String, result: TopicCheckinResult)
    case checkinFailed(cardID: String, message: String)

    case dismissTapped(cardID: String, reason: TopicDismissReason)
    case dismissSucceeded(cardID: String, reason: TopicDismissReason)
    case dismissFailed(cardID: String, message: String)
}

public let topicReducer: Reducer<TopicState, TopicAction> = { state, action in
    switch action {
    case .appear, .refreshRequested:
        if state.cards.isEmpty {
            state.phase = .loading
        }
        state.lastErrorMessage = nil

    case let .cardsLoaded(cards):
        state.cards = cards
        state.phase = cards.isEmpty ? .empty : .ready
        state.lastErrorMessage = nil
        // 草稿与在途集合都按这一版产出剪枝：卡没了，勾选也就没有意义了 ——
        // 而留下来的幽灵 id 会让**下一次**撞上同 id 的卡带着别人的勾选出现。
        let validIDs = Set(cards.map(\.id))
        state.checkinDrafts = state.checkinDrafts.filter { validIDs.contains($0.key) }
        state.checkingInCardIDs = state.checkingInCardIDs.intersection(validIDs)
        state.dismissingCardIDs = state.dismissingCardIDs.intersection(validIDs)

    case let .cardsFailed(message):
        state.phase = .failed
        state.lastErrorMessage = message

    case let .statsLoaded(stats):
        state.stats = stats

    case let .checkinDraftReflectionChanged(cardID, value):
        guard let card = state.card(for: cardID), !card.isCheckedIn else { break }
        // 截在**字节**上，见 `TopicReflection`：服务端按字节判并且会 400。
        var draft = state.draft(for: cardID)
        draft.reflection = TopicReflection.capped(value)
        state.checkinDrafts[cardID] = draft

    case let .checkinDraftBlockToggled(cardID, blockID):
        guard let card = state.card(for: cardID), !card.isCheckedIn else { break }
        // 只能勾这张卡**提供过**的那几条。一个不存在的 id 勾上了也送不出去
        // （`usedBlockIDs(for:)` 会把它滤掉），但放它进草稿会让界面显示一条勾着的幽灵项。
        guard card.blockIDs.contains(blockID) else { break }
        var draft = state.draft(for: cardID)
        if draft.selectedBlockIDs.contains(blockID) {
            draft.selectedBlockIDs.remove(blockID)
        } else {
            draft.selectedBlockIDs.insert(blockID)
        }
        state.checkinDrafts[cardID] = draft

    case let .checkinDraftDiscarded(cardID):
        state.checkinDrafts[cardID] = nil

    case let .checkinTapped(cardID):
        // **in-flight 在「意图」那一刻置位，不在「任务跑起来」那一刻。**
        //
        // 写成一条独立的 `.checkinStarted`（照 `acceptRefineCardTapped` 的形状）会有一个
        // 无解的竞态：两个 `.task` 谁先落地没有保证，而请求那个可能在 `started` 之前就
        // 完成了 —— 于是那个晚到的 `started` 会把一张**已经打卡成功**的卡永久留在
        // 「进行中」，按钮再也点不动。放在这里，置位与请求发射是同一个同步动作。
        guard state.canCheckIn(cardID) else { break }
        state.actionErrorMessage = nil
        state.checkingInCardIDs.insert(cardID)

    case let .checkinSucceeded(cardID, result):
        state.checkingInCardIDs.remove(cardID)
        state.actionErrorMessage = nil
        state.lastCheckin = result
        state.checkinDrafts[cardID] = nil
        // 就地标上「已打卡」，而不是回头再拉一次列表：服务端的 200 已经确认了这件事，
        // 再拉一次只是为了让本地的 `checked_in_at` 更精确 —— 而它唯一的用途是
        // `isCheckedIn`，那个判断与时间戳具体是什么无关。
        if let index = state.cards.firstIndex(where: { $0.id == cardID }) {
            state.cards[index].checkedInAt = Date()
        }

    case let .checkinFailed(cardID, message):
        state.checkingInCardIDs.remove(cardID)
        // **草稿留着**：学员写了字、勾了块，一次网络失败不该把它们抹掉。
        state.actionErrorMessage = message

    case let .dismissTapped(cardID, _):
        // 同 `.checkinTapped`：置位与发射是同一个同步动作。
        guard state.canDismiss(cardID) else { break }
        state.actionErrorMessage = nil
        state.dismissingCardIDs.insert(cardID)

    case let .dismissSucceeded(cardID, reason):
        state.dismissingCardIDs.remove(cardID)
        state.actionErrorMessage = nil
        state.checkinDrafts[cardID] = nil
        if let index = state.cards.firstIndex(where: { $0.id == cardID }) {
            state.cards[index].dismissedAt = Date()
            state.cards[index].dismissReason = reason
        }

    case let .dismissFailed(cardID, message):
        state.dismissingCardIDs.remove(cardID)
        state.actionErrorMessage = message
    }
}
