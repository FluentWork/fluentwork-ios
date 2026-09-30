import FluentWorkCore
import FluentWorkNetworking

/// `TopicState` → `TopicCardsViewModel` 的投影（H1 列表 / H2 来源 / H3 打卡草稿）。
///
/// 住在这里而不是 `App/FluentWorkHost` 的理由与其它投影相同：app target **没有测试 target**，
/// 门禁对它的验证到「能编译」为止，于是「state 里已经有了一个维度、屏幕上却没人读」这类缺陷
/// 在结构上无法被发现。话题卡这一屏尤其容易犯这个错 —— 它的 state 是这一批里最厚的一份
/// （`visibleCards` / `canCheckIn` / `canDismiss` / `usedBlockIDs` / `streakDays` 全是给屏幕准备的），
/// 少读任何一个都不会有东西报错。
extension TopicCardsViewModel {
    public static func make(from state: TopicState) -> TopicCardsViewModel {
        let phase: TopicViewPhase
        switch state.phase {
        case .idle: phase = .idle
        case .loading: phase = .loading
        case .ready: phase = .ready
        case .empty: phase = .empty
        case .failed: phase = .failed
        }

        // **读 `visibleCards`，不读 `cards`。**
        //
        // 已忽略的卡必须离开列表 —— 那是「忽略」这个动作的全部意义。读原始列表会让忽略
        // 按下去之后卡还在（只多一个 `isDismissed` 标记），而屏幕上没有任何东西提示它已经作废。
        let cards = state.visibleCards.map { card in
            TopicCardRow(
                id: card.id,
                title: card.title,
                promptEN: card.promptEN,
                promptZH: card.promptZH,
                // H2：`nil` 原样传下去，见 `TopicCardRow.sourceNote`。
                sourceNote: card.sourceNote,
                blocks: card.blocks.map { block in
                    TopicBlockRow(
                        id: block.id,
                        expressionEN: block.expressionEN,
                        intentZH: block.intentZH,
                        isSelected: state.draft(for: card.id)
                            .selectedBlockIDs
                            .contains(block.id)
                    )
                },
                // 三个「能不能 / 在不在飞」各自问 state，**不在投影里重写规则**：
                // 「打过卡再点一次服务端回 409」这条知识住在 `canCheckIn` 里。
                isCheckedIn: card.isCheckedIn,
                canCheckIn: state.canCheckIn(card.id),
                // 这一条是**屏幕的规则，不是 state 的规则**，所以它写在这里。
                //
                // `state.canDismiss` 刻意不看 `isCheckedIn`（它自己的注释写着两者独立，
                // 服务端 `Service.Dismiss` 也真的不检查打卡状态）。但屏幕上不能这样：
                // 一张刚说过「已和真人聊过」的卡上再挂一个「今天聊不到」，是自相矛盾的两个入口。
                // 所以这里加的是**呈现**条件 —— 「今天聊不到」只对还没聊过的卡有意义。
                canDismiss: state.canDismiss(card.id) && !card.isCheckedIn,
                isCheckingIn: state.checkingInCardIDs.contains(card.id),
                isDismissing: state.dismissingCardIDs.contains(card.id),
                reflection: state.draft(for: card.id).reflection,
                // 「有东西可清」而不是「草稿那条记录在不在」：打字再删光之后记录仍在，
                // 而那时「清空」无事可做。
                canDiscardDraft: draftHasSomethingToClear(state, cardID: card.id)
            )
        }

        return TopicCardsViewModel(
            phase: phase,
            cards: cards,
            checkedInCount: state.checkedInCount,
            streakDays: state.streakDays,
            actionErrorMessage: state.actionErrorMessage,
            lastErrorMessage: state.lastErrorMessage
        )
    }

    private static func draftHasSomethingToClear(_ state: TopicState, cardID: String) -> Bool {
        let draft = state.draft(for: cardID)
        return !draft.reflection.isEmpty || !draft.selectedBlockIDs.isEmpty
    }
}

/// 忽略理由的中文文案（H3 / 86_ M11）。
///
/// **为什么它在这里而不是在 `FluentWorkNetworking`**：`TopicDismissReason` 自己的注释写着
/// 「文案（中文标签）不在这里：写用户可见的中文文案是产品决定…… 四个选项长什么样由 UI 票定」——
/// 这一屏就是那张 UI 票。
///
/// 四句话各自对着服务端文档里那一个修法（`internal/topic/model.go:87-100`）：
/// 没人可聊 → 应用内模拟对话；不敢开口 → 更低的第一步；没时间 → 更短的卡；
/// 话题没用 → 生成还没到位（这是 H1/H2 的质量信号）。所以四句**不许**写成近义词 ——
/// 它们要能把「哪一种最后一公里断了」分开，否则那个可数信号就白收了。
extension TopicDismissReason {
    public var label: String {
        switch self {
        case .noPartner:
            return "没人可聊"
        case .notConfident:
            return "不敢开口"
        case .noTime:
            return "没时间"
        case .notRelevant:
            return "话题没用"
        }
    }
}
