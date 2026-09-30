import FluentWorkNetworking
import SwiftUI

/// 话题建议屏的相位。
///
/// 与 `TopicPhase` 一一对应，**包括 `.empty`**：服务端明说 `GET /topic-cards` 在生成之前
/// 可能是空的，而「今天还没有话题」不是「出错了」—— 两者合成一个相位会让首屏显示成失败页。
public enum TopicViewPhase: Equatable, Sendable {
    case idle
    case loading
    case ready
    case empty
    case failed
}

/// 卡上一条「可调用话术块」的可显示形态。
public struct TopicBlockRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var expressionEN: String
    public var intentZH: String
    /// 学员勾了「这条我用上了」。
    public var isSelected: Bool

    public init(id: String, expressionEN: String, intentZH: String, isSelected: Bool) {
        self.id = id
        self.expressionEN = expressionEN
        self.intentZH = intentZH
        self.isSelected = isSelected
    }
}

/// 一张话题卡的可显示形态。
public struct TopicCardRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var promptEN: String
    public var promptZH: String
    /// H2 的**来源标注**。
    ///
    /// `nil` **原样传下去**，不补默认值、不折成一句泛泛的话：一张没有 `source_note` 的卡
    /// 就是「服务端没能把它落到你的语料上」，那是 H2 要看的信号。屏幕在 `nil` 时**什么都不说**，
    /// 这比编一句「来自你的练习」诚实。
    public var sourceNote: String?
    public var blocks: [TopicBlockRow]

    public var isCheckedIn: Bool
    /// 这三个各自是**独立的事实**，不是一个 `isBusy`：
    /// 「能不能打卡」与「能不能忽略」可以同时为真，而「在飞」是第三个。
    /// 视图读它们，而不是读「有没有这个按钮」—— **「有控件」不等于「控件能用」**。
    public var canCheckIn: Bool
    public var canDismiss: Bool
    public var isCheckingIn: Bool
    public var isDismissing: Bool

    /// 打卡草稿里的那句话。
    public var reflection: String
    /// 这张卡有没有**东西可清** —— 决定「清空」要不要出现。
    ///
    /// 不是「草稿那条记录在不在」：学员打字再删光之后记录仍在，而那时「清空」无事可做。
    public var canDiscardDraft: Bool

    public init(
        id: String,
        title: String,
        promptEN: String,
        promptZH: String,
        sourceNote: String?,
        blocks: [TopicBlockRow],
        isCheckedIn: Bool,
        canCheckIn: Bool,
        canDismiss: Bool,
        isCheckingIn: Bool,
        isDismissing: Bool,
        reflection: String,
        canDiscardDraft: Bool
    ) {
        self.id = id
        self.title = title
        self.promptEN = promptEN
        self.promptZH = promptZH
        self.sourceNote = sourceNote
        self.blocks = blocks
        self.isCheckedIn = isCheckedIn
        self.canCheckIn = canCheckIn
        self.canDismiss = canDismiss
        self.isCheckingIn = isCheckingIn
        self.isDismissing = isDismissing
        self.reflection = reflection
        self.canDiscardDraft = canDiscardDraft
    }
}

public struct TopicCardsViewModel: Equatable, Sendable {
    public var phase: TopicViewPhase
    public var cards: [TopicCardRow]
    /// 今天已经聊过的张数。
    ///
    /// 直接取 `TopicState.checkedInCount`，**不在这里重算** —— 同一个问题两处实现，
    /// 迟早会在「已忽略的卡算不算」这种边上分叉。
    public var checkedInCount: Int
    /// 连续打卡天数。只在这一次打卡之后有值（服务端不给单独的 streak 查询）。
    public var streakDays: Int?
    /// 打卡/忽略失败的原因，与整屏加载失败分开：一个是「这次动作没成」，
    /// 一个是「这一屏没有内容」。
    public var actionErrorMessage: String?
    public var lastErrorMessage: String?

    public init(
        phase: TopicViewPhase,
        cards: [TopicCardRow] = [],
        checkedInCount: Int = 0,
        streakDays: Int? = nil,
        actionErrorMessage: String? = nil,
        lastErrorMessage: String? = nil
    ) {
        self.phase = phase
        self.cards = cards
        self.checkedInCount = checkedInCount
        self.streakDays = streakDays
        self.actionErrorMessage = actionErrorMessage
        self.lastErrorMessage = lastErrorMessage
    }

    public var showsRetryAction: Bool { phase == .failed }
}

public struct TopicCardsRootView: View {
    private let model: TopicCardsViewModel
    private let onAppear: () -> Void
    private let onRefresh: () -> Void
    private let onReflectionChanged: (String, String) -> Void
    private let onToggleBlock: (String, String) -> Void
    private let onDiscardDraft: (String) -> Void
    private let onCheckIn: (String) -> Void
    private let onDismiss: (String, TopicDismissReason) -> Void

    public init(
        model: TopicCardsViewModel,
        onAppear: @escaping () -> Void,
        onRefresh: @escaping () -> Void,
        onReflectionChanged: @escaping (String, String) -> Void,
        onToggleBlock: @escaping (String, String) -> Void,
        onDiscardDraft: @escaping (String) -> Void,
        onCheckIn: @escaping (String) -> Void,
        onDismiss: @escaping (String, TopicDismissReason) -> Void
    ) {
        self.model = model
        self.onAppear = onAppear
        self.onRefresh = onRefresh
        self.onReflectionChanged = onReflectionChanged
        self.onToggleBlock = onToggleBlock
        self.onDiscardDraft = onDiscardDraft
        self.onCheckIn = onCheckIn
        self.onDismiss = onDismiss
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.s6) {
                header
                actionError
                content
            }
            .padding(DesignTokens.Spacing.pageMargin)
        }
        .navigationTitle("话题建议")
        .task {
            onAppear()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s2) {
            Text("基于你已练过的话术块生成 · 每周更新")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Color.textSecondary)

            if !model.cards.isEmpty {
                // 只报一个数，不报第二个分母：屏幕上的卡数是 `visibleCards`，
                // 而已聊过那个数来自 state 的全量计数 —— 两个基数不同，
                // 并排写出来会在「忽略了又聊过」这种边上自相矛盾。
                Text("今天已聊过 \(model.checkedInCount) 张")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
            }

            if let streakDays = model.streakDays {
                Text("连续 \(streakDays) 天")
                    .font(DesignTokens.Typography.cardTitle)
                    .foregroundStyle(DesignTokens.Color.success)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var actionError: some View {
        if let message = model.actionErrorMessage, !message.isEmpty {
            Text(message)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Color.improve)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .loading:
            ProgressView("正在取今天的话题…")
                .frame(maxWidth: .infinity)
        case .empty:
            // 「今天还没有话题」不是失败：服务端在生成之前就是空的。
            ContentUnavailableView(
                "今天还没有话题",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("生成之后这里会列出今天该聊的那几件。")
            )
        case .failed:
            VStack(spacing: DesignTokens.Spacing.s3) {
                ContentUnavailableView(
                    "话题建议加载失败",
                    systemImage: "exclamationmark.triangle",
                    description: Text(model.lastErrorMessage ?? "请稍后重试。")
                )
                Button("重试") {
                    onRefresh()
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
        case .ready:
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.s6) {
                ForEach(model.cards) { card in
                    TopicCardView(
                        card: card,
                        onReflectionChanged: { value in
                            onReflectionChanged(card.id, value)
                        },
                        onToggleBlock: { blockID in
                            onToggleBlock(card.id, blockID)
                        },
                        onDiscardDraft: {
                            onDiscardDraft(card.id)
                        },
                        onCheckIn: {
                            onCheckIn(card.id)
                        },
                        onDismiss: { reason in
                            onDismiss(card.id, reason)
                        }
                    )
                }
            }
        }
    }
}

private struct TopicCardView: View {
    let card: TopicCardRow
    let onReflectionChanged: (String) -> Void
    let onToggleBlock: (String) -> Void
    let onDiscardDraft: () -> Void
    let onCheckIn: () -> Void
    let onDismiss: (TopicDismissReason) -> Void

    @State private var showsDismissOptions = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s3) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.s2) {
                Text(card.title)
                    .font(DesignTokens.Typography.cardTitle)
                    .foregroundStyle(DesignTokens.Color.textPrimary)
                Spacer(minLength: DesignTokens.Spacing.s2)
                if card.isCheckedIn {
                    Label("今天聊过", systemImage: "checkmark.circle.fill")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Color.success)
                }
            }

            // H2：没有来源标注就**不渲染这一行**。补一句泛泛的「来自你的练习」会把这个信号抹掉。
            if let sourceNote = card.sourceNote, !sourceNote.isEmpty {
                Text("来源：\(sourceNote)")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.s1) {
                Text(card.promptEN)
                    .font(DesignTokens.Typography.englishPhrase)
                    .foregroundStyle(DesignTokens.Color.accent)
                Text(card.promptZH)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
            }

            if !card.blocks.isEmpty {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.s2) {
                    Text("你已经会的这几句")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Color.textSecondary)

                    ForEach(card.blocks) { block in
                        blockButton(block)
                    }
                }
            }

            if !card.isCheckedIn {
                reflectionField
            }

            HStack(spacing: DesignTokens.Spacing.s3) {
                checkInButton
                dismissButton
            }
        }
        .padding(DesignTokens.Spacing.s4)
        .background(DesignTokens.Color.backgroundElevated)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous))
        .accessibilityIdentifier("topic.card.\(card.id)")
    }

    private func blockButton(_ block: TopicBlockRow) -> some View {
        Button {
            onToggleBlock(block.id)
        } label: {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.s2) {
                Image(systemName: block.isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(
                        block.isSelected
                            ? DesignTokens.Color.accent
                            : DesignTokens.Color.textSecondary
                    )
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.s1) {
                    Text(block.expressionEN)
                        .font(DesignTokens.Typography.englishPhrase)
                        .foregroundStyle(DesignTokens.Color.accent)
                        .multilineTextAlignment(.leading)
                    Text(block.intentZH)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignTokens.Spacing.s2)
            .background(block.isSelected ? DesignTokens.Color.wash : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(card.isCheckedIn)
        // 热区不缩水：勾选这一下有 ≥44pt 的可点面积。
        .frame(minHeight: DesignTokens.Component.minHitTarget)
        .accessibilityAddTraits(block.isSelected ? [.isSelected] : [])
    }

    private var reflectionField: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s2) {
            TextField(
                "聊完回来记一句",
                text: Binding(
                    get: { card.reflection },
                    set: { onReflectionChanged($0) }
                ),
                axis: .vertical
            )
            .font(DesignTokens.Typography.body)
            .lineLimit(2...4)

            if card.canDiscardDraft {
                Button("清空") {
                    onDiscardDraft()
                }
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Color.textSecondary)
            }
        }
    }

    private var checkInButton: some View {
        Button {
            onCheckIn()
        } label: {
            Text(checkInLabel)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(DesignTokens.Color.brandStrong)
        // 三个事实各自决定一件事：文字说「在飞」，`canCheckIn` 说「能不能点」。
        .disabled(!card.canCheckIn || card.isCheckingIn)
    }

    private var checkInLabel: String {
        if card.isCheckedIn { return "今天已聊过" }
        if card.isCheckingIn { return "正在记下…" }
        // 设计稿 屏 10 的原话：打卡按钮不是「提交」，是「已和真人聊过」。
        return "已和真人聊过"
    }

    private var dismissButton: some View {
        Button {
            showsDismissOptions = true
        } label: {
            Text(card.isDismissing ? "正在忽略…" : "今天聊不到")
        }
        .buttonStyle(.bordered)
        .disabled(!card.canDismiss || card.isDismissing)
        .confirmationDialog(
            "今天为什么聊不到？",
            isPresented: $showsDismissOptions,
            titleVisibility: .visible
        ) {
            // 四选一，闭集。文案在中性语境下说清「是哪一种最后一公里断了」——
            // 服务端拿它做的是**可数**的信号，不是自由文本。
            ForEach(TopicDismissReason.allCases, id: \.self) { reason in
                Button(reason.label) {
                    onDismiss(reason)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("说一句原因，明天生成的卡会更贴近你。")
        }
    }
}
