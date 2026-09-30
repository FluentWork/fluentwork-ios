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
    public var isAccepting: Bool
    public var isAccepted: Bool
    /// 这一张学员改过（D2）。视图据此标出「已修改」。
    public var isEdited: Bool

    public init(
        id: String,
        intentZH: String,
        expressionEN: String,
        anchorUserSaid: String,
        isAccepting: Bool = false,
        isAccepted: Bool = false,
        isEdited: Bool = false
    ) {
        self.id = id
        self.intentZH = intentZH
        self.expressionEN = expressionEN
        self.anchorUserSaid = anchorUserSaid
        self.isAccepting = isAccepting
        self.isAccepted = isAccepted
        self.isEdited = isEdited
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

    public init(
        model: ReviewViewModel,
        onAppear: @escaping () -> Void,
        onRetry: @escaping () -> Void = {},
        onAcceptRefineCard: @escaping (String) -> Void = { _ in }
    ) {
        self.model = model
        self.onAppear = onAppear
        self.onRetry = onRetry
        self.onAcceptRefineCard = onAcceptRefineCard
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
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(card.intentZH)
                                        .font(.headline)
                                    Text(card.expressionEN)
                                    Text(card.anchorUserSaid)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer(minLength: 12)

                                Button(buttonTitle(for: card)) {
                                    onAcceptRefineCard(card.id)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(card.isAccepting || card.isAccepted)
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

    private func buttonTitle(for card: ReviewRefineCardRow) -> String {
        if card.isAccepted {
            return "已加入"
        }
        if card.isAccepting {
            return "加入中..."
        }
        return "加入语料库"
    }
}
