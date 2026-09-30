import FluentWorkCore
import SwiftUI

public enum ReviewViewPhase: Equatable, Sendable {
    case idle
    case loading
    case pending
    case ready
    case failed
}

public struct ReviewOverviewViewData: Equatable, Sendable {
    public var note: String
    public var issueCount: Int
    public var suggestionCount: Int
    public var comparisonCount: Int

    public init(note: String, issueCount: Int, suggestionCount: Int, comparisonCount: Int) {
        self.note = note
        self.issueCount = issueCount
        self.suggestionCount = suggestionCount
        self.comparisonCount = comparisonCount
    }
}

public struct ReviewTranscriptRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var speaker: String
    public var text: String

    public init(id: String, speaker: String, text: String) {
        self.id = id
        self.speaker = speaker
        self.text = text
    }
}

public struct ReviewComparisonRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var user: String
    public var better: String

    public init(id: String, user: String, better: String) {
        self.id = id
        self.user = user
        self.better = better
    }
}

public struct ReviewRefineCardRow: Equatable, Sendable, Identifiable {
    /// **稳定键**：原卡（服务端给的那张）的 id。
    ///
    /// 不是「现在显示的这一版的 id」：`RefineCard.id` 是内容派生的
    /// （`expressionEN-anchorUserSaid`），学员改一个字它就换一个 —— 视图若拿它回派
    /// （入库 / 再编辑 / 撤回），改完第一个字符就再也找不到自己，而这条路上不会报任何错。
    public var id: String
    public var intentZH: String
    public var expressionEN: String
    public var anchorUserSaid: String
    /// 场景 / 功能标签。它们**也是可编辑字段**（`RefineCardEditField` 里那五个之一），
    /// 而且入库时会跟着一起送上去 —— 所以它们必须能到屏幕上，否则编辑面板会有两个字段
    /// 没有出处。
    public var sceneTag: String
    public var functionTag: String
    public var isAccepting: Bool
    public var isAccepted: Bool
    /// 这一张学员改过（D2）。视图据此标出「已修改」。
    public var isEdited: Bool
    /// 还能不能改、还能不能丢。
    ///
    /// **两条都是屏幕的规则，不是 state 的规则**：reducer 只挡「已经丢掉的卡不许再改」，
    /// 它不挡「已经入库的卡」。但屏幕上说不通 —— 这一屏改的、丢的是**「将要入库的那一版」**，
    /// 而入库已经发生在前面了：再改一个字符不会回流到语料库，再丢一次只会让一张已经在库里的
    /// 卡从这一屏消失。两个入口都撤掉，比留着两个动了没反应的按钮诚实。
    ///
    /// 「入库请求在飞」也一起挡住：那时草稿已经被请求读走，再改只会造成
    /// 「屏幕上看到的」与「已经送上去的」不一致。
    public var canEdit: Bool
    public var canDiscard: Bool

    public init(
        id: String,
        intentZH: String,
        expressionEN: String,
        anchorUserSaid: String,
        sceneTag: String = "",
        functionTag: String = "",
        isAccepting: Bool = false,
        isAccepted: Bool = false,
        isEdited: Bool = false,
        canEdit: Bool = true,
        canDiscard: Bool = true
    ) {
        self.id = id
        self.intentZH = intentZH
        self.expressionEN = expressionEN
        self.anchorUserSaid = anchorUserSaid
        self.sceneTag = sceneTag
        self.functionTag = functionTag
        self.isAccepting = isAccepting
        self.isAccepted = isAccepted
        self.isEdited = isEdited
        self.canEdit = canEdit
        self.canDiscard = canDiscard
    }
}

public struct ReviewViewModel: Equatable, Sendable {
    public var phase: ReviewViewPhase
    public var overview: ReviewOverviewViewData?
    public var transcript: [ReviewTranscriptRow]
    public var dualColumn: [ReviewComparisonRow]
    public var refineCards: [ReviewRefineCardRow]
    /// 被丢掉的那几张，供「撤回」用。`refineCards` 里没有它们。
    public var discardedRefineCards: [ReviewRefineCardRow]
    public var refineErrorMessage: String?
    public var errorMessage: String?

    public init(
        phase: ReviewViewPhase,
        overview: ReviewOverviewViewData? = nil,
        transcript: [ReviewTranscriptRow] = [],
        dualColumn: [ReviewComparisonRow] = [],
        refineCards: [ReviewRefineCardRow] = [],
        discardedRefineCards: [ReviewRefineCardRow] = [],
        refineErrorMessage: String? = nil,
        errorMessage: String? = nil
    ) {
        self.phase = phase
        self.overview = overview
        self.transcript = transcript
        self.dualColumn = dualColumn
        self.refineCards = refineCards
        self.discardedRefineCards = discardedRefineCards
        self.refineErrorMessage = refineErrorMessage
        self.errorMessage = errorMessage
    }
}

public struct ReviewRootView: View {
    private let model: ReviewViewModel
    private let onAppear: () -> Void
    private let onRetry: () -> Void
    private let onAcceptRefineCard: (String) -> Void
    private let onDiscardRefineCard: (String) -> Void
    private let onRestoreRefineCard: (String) -> Void
    private let onEditRefineCard: (String, RefineCardEditField, String) -> Void
    private let onRevertRefineCardEdits: (String) -> Void

    public init(
        model: ReviewViewModel,
        onAppear: @escaping () -> Void,
        onRetry: @escaping () -> Void = {},
        onAcceptRefineCard: @escaping (String) -> Void = { _ in },
        onDiscardRefineCard: @escaping (String) -> Void = { _ in },
        onRestoreRefineCard: @escaping (String) -> Void = { _ in },
        onEditRefineCard: @escaping (String, RefineCardEditField, String) -> Void = { _, _, _ in },
        onRevertRefineCardEdits: @escaping (String) -> Void = { _ in }
    ) {
        self.model = model
        self.onAppear = onAppear
        self.onRetry = onRetry
        self.onAcceptRefineCard = onAcceptRefineCard
        self.onDiscardRefineCard = onDiscardRefineCard
        self.onRestoreRefineCard = onRestoreRefineCard
        self.onEditRefineCard = onEditRefineCard
        self.onRevertRefineCardEdits = onRevertRefineCardEdits
    }

    public var body: some View {
        content
            .navigationTitle("回顾")
            .task {
                onAppear()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .loading, .pending:
            VStack(alignment: .leading, spacing: 12) {
                Text("回顾生成中")
                    .font(.headline)
                Text("正在等待转录、评价与炼化内容。")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding()

        case .failed:
            VStack(alignment: .leading, spacing: 12) {
                Text("回顾暂不可用")
                    .font(.headline)
                Text(model.errorMessage ?? "请稍后重试。")
                    .foregroundStyle(.secondary)
                Button("重试") {
                    onRetry()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding()

        case .ready:
            if let overview = model.overview {
                List {
                    Section("Overview") {
                        Text(overview.note)
                        LabeledContent("Issues", value: "\(overview.issueCount)")
                        LabeledContent("Suggestions", value: "\(overview.suggestionCount)")
                        LabeledContent("Comparisons", value: "\(overview.comparisonCount)")
                    }

                    Section("Transcript") {
                        ForEach(model.transcript) { turn in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(turn.speaker)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(turn.text)
                            }
                        }
                    }

                    Section("Dual Column") {
                        ForEach(model.dualColumn) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("You: \(row.user)")
                                Text("Better: \(row.better)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Section("Refine Cards") {
                        if let refineErrorMessage = model.refineErrorMessage, !refineErrorMessage.isEmpty {
                            Text(refineErrorMessage)
                                .foregroundStyle(.red)
                        }

                        ForEach(model.refineCards) { card in
                            ReviewRefineCardView(
                                card: card,
                                onAccept: {
                                    onAcceptRefineCard(card.id)
                                },
                                onDiscard: {
                                    onDiscardRefineCard(card.id)
                                },
                                onEdit: { field, value in
                                    onEditRefineCard(card.id, field, value)
                                },
                                onRevertEdits: {
                                    onRevertRefineCardEdits(card.id)
                                }
                            )
                        }
                    }

                    // 撤回的入口。**没有这一段，「撤回」就是一条到不了屏幕的动作** ——
                    // 被丢掉的卡不在 `refineCards` 里，`discardedRefineCards` 是它们唯一的出处。
                    if !model.discardedRefineCards.isEmpty {
                        Section("已丢弃") {
                            ForEach(model.discardedRefineCards) { card in
                                HStack(alignment: .top, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(card.intentZH)
                                            .font(.headline)
                                        Text(card.expressionEN)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer(minLength: 12)

                                    Button("撤回") {
                                        onRestoreRefineCard(card.id)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }
            } else {
                Text("回顾内容缺失")
                    .foregroundStyle(.secondary)
            }
        }
    }

}

/// 一张炼化卡：读它、改它、丢掉它、入库。
///
/// 展开状态是**每一行自己的** `@State`（不是整页一个 `editingCardID`，也不是 sheet）：
/// 编辑时每一次按键都要经过 store 再回到这里，而 sheet 的内容闭包在呈现那一刻就被捕获了 ——
/// 用它装「正在编辑的那张卡」，输入框会一直显示**打开时的那一份**，学员改了字却看不见。
/// 行内展开没有这个问题：`card` 每帧都是最新投影。
private struct ReviewRefineCardView: View {
    let card: ReviewRefineCardRow
    let onAccept: () -> Void
    let onDiscard: () -> Void
    let onEdit: (RefineCardEditField, String) -> Void
    let onRevertEdits: () -> Void

    @State private var isEditing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(card.intentZH)
                    .font(.headline)
                if card.isEdited {
                    Text("已修改")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.18), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            Text(card.expressionEN)
            Text(card.anchorUserSaid)
                .foregroundStyle(.secondary)

            if !card.sceneTag.isEmpty || !card.functionTag.isEmpty {
                Text([card.sceneTag, card.functionTag]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isEditing {
                editor
            }

            HStack(spacing: 12) {
                Button(buttonTitle) {
                    onAccept()
                }
                .buttonStyle(.borderedProminent)
                .disabled(card.isAccepting || card.isAccepted)

                Button(isEditing ? "收起" : "编辑") {
                    isEditing.toggle()
                }
                .buttonStyle(.bordered)
                .disabled(!card.canEdit)

                Button("丢弃") {
                    onDiscard()
                }
                .buttonStyle(.bordered)
                .foregroundStyle(.secondary)
                .disabled(!card.canDiscard)

                Spacer(minLength: 0)
            }
        }
    }

    /// 编辑面板按 `RefineCardEditField.allCases` 铺开，**不手抄五个输入框**：
    /// 那样的话枚举里多一个字段，屏幕上会安静地少一个入口，而编译器什么都不会说。
    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(RefineCardEditField.allCases, id: \.self) { field in
                VStack(alignment: .leading, spacing: 4) {
                    Text(field.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(field.label, text: binding(for: field))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
            }

            if card.isEdited {
                Button("还原我的修改") {
                    onRevertEdits()
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    private var buttonTitle: String {
        if card.isAccepted {
            return "已加入"
        }
        if card.isAccepting {
            return "加入中..."
        }
        return "加入语料库"
    }

    /// 读的是**这一版**（有草稿就是草稿），写回通过回调 —— 与语料库搜索框、话题卡打卡草稿
    /// 同一个形状：视图不持有副本，状态只有 store 那一处。
    private func binding(for field: RefineCardEditField) -> Binding<String> {
        Binding(
            get: {
                switch field {
                case .intentZH: return card.intentZH
                case .expressionEN: return card.expressionEN
                case .anchorUserSaid: return card.anchorUserSaid
                case .sceneTag: return card.sceneTag
                case .functionTag: return card.functionTag
                }
            },
            set: { onEdit(field, $0) }
        )
    }
}
