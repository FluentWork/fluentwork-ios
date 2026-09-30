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
            refineErrorMessage: state.acceptErrorMessage,
            errorMessage: state.lastErrorMessage
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
