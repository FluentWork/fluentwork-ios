import FluentWorkCore
import FluentWorkNetworking

/// `AppState` → `ReviewViewModel` 的投影。
///
/// ## 为什么它住在这里，而不是在 `App/FluentWorkHost`
///
/// 这一层原本是 Host 里的一个 `private func makeReviewViewModel(from:)`。那里是 **app target**，
/// 而 app target **没有测试 target**（`project.yml` 只声明一个 `type: application`），
/// 门禁腿 2 对它的验证**到「能编译」为止**（`Scripts/gate.sh:22-42` 是 `xcodebuild … build`
/// 加数 `error:`）。于是「state 里已经有了一个维度、屏幕上却没人读」这类缺陷
/// **在结构上无法被发现** —— 随手做一个实验就能看出来：把下面任何一行改成读
/// `payload.refineCards`，`swift test` 与门禁**都是绿的**。
///
/// 搬到这里之后 `@testable import FluentWorkUI` 就能碰到它（`FluentWorkUI` 本身就依赖
/// `FluentWorkCore`，所以不需要动 `Package.swift`），于是每条维度都能有一条判据。
extension ReviewViewModel {
    public static func make(from state: ReviewState) -> ReviewViewModel {
        let phase: ReviewViewPhase
        switch state.phase {
        case .idle:
            phase = .idle
        case .loading:
            phase = .loading
        case .pending:
            phase = .pending
        case .ready:
            phase = .ready
        case .failed:
            phase = .failed
        }

        let overview = state.payload.map {
            ReviewOverviewViewData(
                note: $0.overview.goalAchievement.note,
                issueCount: $0.overview.issueCount,
                suggestionCount: $0.overview.suggestionCount,
                comparisonCount: $0.overview.comparisonCount
            )
        }
        let transcript = state.payload?.transcript.map {
            ReviewTranscriptRow(id: $0.id, speaker: $0.speaker, text: $0.text)
        } ?? []
        let dualColumn = state.payload?.dualColumn.map {
            ReviewComparisonRow(id: $0.id, user: $0.user, better: $0.better)
        } ?? []
        // **读 `visibleRefineCards`，不读 `payload.refineCards`**（D2）。
        //
        // 这两个读法之间隔着一条 796 条判据都看不见的鸿沟：丢掉一张卡是
        // `state.discardedRefineCardIDs` 的事，产出（`payload`）一个字都不动 ——
        // 读产出等于「丢弃这个功能在屏幕上不存在」。搬进来之后
        // `theCardsOnScreenAreTheVisibleOnesNotTheRawPayload` 会让它红。
        //
        // `id` 取 **`entry.key`**（原卡 id）而不是 `entry.card.id`：后者是内容派生的，
        // 学员改一个字它就换一个，用它回派（入库 / 再编辑 / 撤回）就再也找不到自己。
        let refineCards = state.visibleRefineCards.map { row(from: state, entry: $0) }
        // 撤回的入口：被丢掉的那几张仍然要读得到，否则 `restoreRefineCardTapped`
        // 是一条**没有入口的动作**。
        let discarded = state.discardedRefineCards.map { row(from: state, entry: $0) }

        return ReviewViewModel(
            phase: phase,
            overview: overview,
            transcript: transcript,
            dualColumn: dualColumn,
            refineCards: refineCards,
            discardedRefineCards: discarded,
            summary: summary(from: state),
            goal: goal(from: state),
            issueCountText: countText(
                count: state.payload?.review.issues.count ?? 0,
                label: "问题清单"
            ),
            suggestionCountText: countText(
                count: state.payload?.review.suggestions.count ?? 0,
                label: "提高建议"
            ),
            comparisonSection: comparisonSection(from: state),
            issueSection: issueSection(from: state),
            suggestionSection: suggestionSection(from: state),
            pendingRefineText: pendingRefineText(cards: refineCards),
            // 直通 state 的规则，不在这里重写一遍 —— 理由见 `ReviewViewModel.showsSkeleton`。
            showsSkeleton: state.showsSkeleton,
            refineErrorMessage: state.acceptErrorMessage,
            errorMessage: state.lastErrorMessage
        )
    }

    // MARK: - 屏 04 的版式

    /// 顶部那一条：**有几个事实就写几项**，不拿 0 去占位。
    ///
    /// 三个数字的出处各不相同，而「没有」在这三处都真的可能发生（时长是可选字段、
    /// 转录可能为空、一块都没提炼出来也合法）—— 写「0 回合」「+0 新增话术块」是在把
    /// 「没有这一项」说成「这一项是零」，两件事。
    private static func summary(from state: ReviewState) -> ReviewSummaryViewData? {
        guard let payload = state.payload else { return nil }

        var facts: [String] = []
        if let durationText = durationText(seconds: payload.durationSec) {
            facts.append(durationText)
        }
        // 「回合」数是**学员自己说了几轮**，不是转录的总行数：AI 的话不算学员的回合。
        let userRounds = payload.transcript.filter { $0.speaker == "user" }.count
        if userRounds > 0 {
            facts.append("\(userRounds) 回合")
        }
        if let blocks = newBlockCount(from: state), blocks > 0 {
            facts.append("+\(blocks) 新增话术块")
        }

        return facts.isEmpty ? nil : ReviewSummaryViewData(facts: facts)
    }

    /// 时长取整到分钟，**最少 1 分钟**：说了 20 秒也发生过，写「0 分钟」是把它说成没练。
    private static func durationText(seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let minutes = max(1, Int((Double(seconds) / 60).rounded()))
        return "\(minutes) 分钟"
    }

    /// 这一次**提炼出**了多少块（产出，不是进度）。
    ///
    /// 取 `refine.blocks`（`refine_cards` 是它的同一个来源），并且**与入库与否无关** ——
    /// 所以「全部入库」之后这个数不变，变的只是「待入库」。
    private static func newBlockCount(from state: ReviewState) -> Int? {
        guard let payload = state.payload else { return nil }
        if !payload.refine.blocks.isEmpty {
            return payload.refine.blocks.count
        }
        return payload.refineCards.count
    }

    /// 目标达成。`met` 直接来自服务端 —— **不在这里重新判断一次**：
    /// 「这次的目标有没有达成」不是客户端能算的东西。
    private static func goal(from state: ReviewState) -> ReviewGoalViewData? {
        guard let achievement = state.payload?.overview.goalAchievement else { return nil }
        return ReviewGoalViewData(
            isMet: achievement.met,
            headline: achievement.met ? "目标达成" : "目标还差一点",
            note: achievement.note
        )
    }

    private static func countText(count: Int, label: String) -> String? {
        count > 0 ? "\(label) \(count) 条" : nil
    }

    /// 「N 个待入库」＝**还没入库的那些**。
    ///
    /// 不是 `refineCards.count`：已入库的卡**仍然留在屏幕上**（带着「已入库」的标记，
    /// 学员还要能对照、能撤回丢弃），拿总张数当「待入库」会让这个数在点完「全部入库」之后
    /// 一个都不减 —— 那条计数就成了摆设。
    private static func pendingRefineText(cards: [ReviewRefineCardRow]) -> String? {
        let pending = cards.filter { !$0.isAccepted }.count
        return pending > 0 ? "\(pending) 个待入库" : nil
    }

    private static func comparisonSection(from state: ReviewState) -> ReviewComparisonSection? {
        guard let payload = state.payload, let top = payload.dualColumn.first else { return nil }
        let all = payload.dualColumn.map { row in
            let segments = ReviewTextDiff.segments(lhs: row.user, rhs: row.better)
            return ReviewComparisonViewData(
                id: row.id,
                userText: row.user,
                betterText: row.better,
                userSegments: segments.lhs,
                betterSegments: segments.rhs
            )
        }
        return ReviewComparisonSection(
            top: all[0],
            remaining: Array(all.dropFirst()),
            counterText: "1 / \(all.count)",
            moreButtonTitle: all.count > 1 ? "查看其余 \(all.count - 1) 条对照" : nil
        )
    }

    private static func issueSection(from state: ReviewState) -> ReviewInsightSection? {
        let issues = state.payload?.review.issues ?? []
        guard let top = issues.first else { return nil }
        let all = issues.map {
            ReviewInsightViewData(id: $0.id, title: $0.originalQuote, detail: $0.hint)
        }
        return ReviewInsightSection(
            top: all[0],
            remaining: Array(all.dropFirst()),
            moreButtonTitle: all.count > 1 ? "查看全部 \(all.count) 条" : nil
        )
    }

    private static func suggestionSection(from state: ReviewState) -> ReviewInsightSection? {
        let suggestions = state.payload?.review.suggestions ?? []
        guard !suggestions.isEmpty else { return nil }
        let all = suggestions.map { ReviewInsightViewData(id: $0.id, title: $0.text) }
        return ReviewInsightSection(
            top: all[0],
            remaining: Array(all.dropFirst()),
            moreButtonTitle: all.count > 1 ? "查看全部 \(all.count) 条" : nil
        )
    }

    private static func row(
        from state: ReviewState,
        entry: VisibleRefineCard
    ) -> ReviewRefineCardRow {
        let isAccepting = state.acceptingRefineCardIDs.contains(entry.key)
        let isAccepted = state.acceptedRefineCardIDs.contains(entry.key)
        return ReviewRefineCardRow(
            id: entry.key,
            intentZH: entry.card.intentZH,
            expressionEN: entry.card.expressionEN,
            anchorUserSaid: entry.card.anchorUserSaid,
            // 这两个也来自 `entry.card`（有草稿就是草稿）：它们是 `RefineCardEditField` 里
            // 的五个字段之二，入库时会跟着一起送上去，所以编辑面板的每个输入框都要有出处。
            sceneTag: entry.card.sceneTag,
            functionTag: entry.card.functionTag,
            // 两个标记都按**稳定键**查：state 里那两个集合装的就是原卡 id
            // （动作带的是它，reducer 也按它剪枝）。
            isAccepting: isAccepting,
            isAccepted: isAccepted,
            isEdited: entry.isEdited,
            // 屏幕的规则，见 `ReviewRefineCardRow.canEdit`。
            canEdit: !isAccepting && !isAccepted,
            canDiscard: !isAccepting && !isAccepted
        )
    }
}

/// 可编辑字段的中文标签（D2）。
///
/// 编辑面板按 `RefineCardEditField.allCases` 铺开，标签从这里取 —— 于是「枚举里加了字段、
/// 屏幕上没有它的输入框」这件事在**编译期**就不成立（`label` 的 switch 是穷举的），
/// 而「两个字段用了同一句话」由判据钉住。
extension RefineCardEditField {
    public var label: String {
        switch self {
        case .intentZH:
            return "意图"
        case .expressionEN:
            return "英文表达"
        case .anchorUserSaid:
            return "你当时说的"
        case .sceneTag:
            return "场景"
        case .functionTag:
            return "功能"
        }
    }
}
