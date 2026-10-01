import FluentWorkCore
import SwiftUI

public enum CorpusViewPhase: Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed
    case migrating
}

public struct CorpusRowViewData: Equatable, Sendable, Identifiable {
    public var id: String
    public var intentZH: String
    public var expressionEN: String
    public var anchorUserSaid: String
    public var sceneTag: String
    public var functionTag: String
    /// 场景的中文标签（认不出的取值 → `nil`，见 `CorpusSceneFilter`）。
    public var sceneLabel: String?
    public var functionLabel: String?
    public var isFavorite: Bool
    public var hasPendingFavorite: Bool
    public var hasPendingDelete: Bool
    public var updatedAt: String
    /// 状态灯（F2）。`nil` = 服务端给的取值我们认不出 —— 那时**不画灯**，见 `CorpusStateLamp`。
    public var lamp: CorpusStateLamp?
    /// 「开会用上过 N 次」（`real_use_count`）。**只有已自动化且真的用过才有值**，
    /// 规则在投影里（`realUseNote(count:lamp:)`）—— 视图只决定把它画在哪。
    public var realUseNote: String?

    public init(
        id: String,
        intentZH: String,
        expressionEN: String,
        anchorUserSaid: String,
        sceneTag: String,
        functionTag: String,
        sceneLabel: String? = nil,
        functionLabel: String? = nil,
        isFavorite: Bool,
        hasPendingFavorite: Bool = false,
        hasPendingDelete: Bool = false,
        updatedAt: String,
        lamp: CorpusStateLamp?,
        realUseNote: String? = nil
    ) {
        self.id = id
        self.intentZH = intentZH
        self.expressionEN = expressionEN
        self.anchorUserSaid = anchorUserSaid
        self.sceneTag = sceneTag
        self.functionTag = functionTag
        self.sceneLabel = sceneLabel
        self.functionLabel = functionLabel
        self.isFavorite = isFavorite
        self.hasPendingFavorite = hasPendingFavorite
        self.hasPendingDelete = hasPendingDelete
        self.updatedAt = updatedAt
        self.lamp = lamp
        self.realUseNote = realUseNote
    }
}

public struct CorpusViewModel: Equatable, Sendable {
    /// 一枚筛选 chip。
    public struct FilterChip: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var isSelected: Bool

        public init(id: String, title: String, isSelected: Bool) {
            self.id = id
            self.title = title
            self.isSelected = isSelected
        }
    }

    /// 空列表的两种成因。**它们不是同一件事**：一个换筛选条件就有，另一个要去练一次。
    public enum EmptyState: Equatable, Sendable {
        /// 库里一个话术块都没有。
        case noBlocks
        /// 有块，但筛完是空的。
        case noMatches
    }

    public var phase: CorpusViewPhase
    public var rows: [CorpusRowViewData]
    public var searchQuery: String
    public var favoriteOnly: Bool
    public var isRefreshing: Bool
    public var isReplayingOutbox: Bool
    public var canLoadMore: Bool
    public var errorMessage: String?
    /// 标题旁那一行计数（筛选时是「筛出 3 / 24」）。
    public var blockCountLabel: String
    /// 列表还没取完 —— 计数与筛选都只覆盖已加载的部分，屏幕上要说出来。
    public var showsUnloadedNote: Bool
    public var sceneOptions: [FilterChip]
    public var functionOptions: [FilterChip]
    public var emptyState: EmptyState?

    public init(
        phase: CorpusViewPhase,
        rows: [CorpusRowViewData] = [],
        searchQuery: String = "",
        favoriteOnly: Bool = false,
        isRefreshing: Bool = false,
        isReplayingOutbox: Bool = false,
        canLoadMore: Bool = false,
        errorMessage: String? = nil,
        blockCountLabel: String = "",
        showsUnloadedNote: Bool = false,
        sceneOptions: [FilterChip] = [],
        functionOptions: [FilterChip] = [],
        emptyState: EmptyState? = nil
    ) {
        self.phase = phase
        self.rows = rows
        self.searchQuery = searchQuery
        self.favoriteOnly = favoriteOnly
        self.isRefreshing = isRefreshing
        self.isReplayingOutbox = isReplayingOutbox
        self.canLoadMore = canLoadMore
        self.errorMessage = errorMessage
        self.blockCountLabel = blockCountLabel
        self.showsUnloadedNote = showsUnloadedNote
        self.sceneOptions = sceneOptions
        self.functionOptions = functionOptions
        self.emptyState = emptyState
    }
}

/// 语料库（09-26 稿 屏 08）。
///
/// 稿子给的三件事，都在这一屏上：
///
/// 1. **三段式卡片**：中文意图（顶部加粗）/ 英文块（强调色，可点按听发音）/ 对比锚点（可折叠）
///    ＋ 右上角状态灯；已自动化的块多一行「开会用上过 N 次」。
/// 2. **场景 / 功能双维度筛选** ＋ 关键词搜索（F1）、收藏（F3）、右滑快捷操作、单条删除（F4）。
/// 3. **空态用状态灯的三个形态纵向排成一条进度轴** —— 图形本身就在说明这个页面接下来会发生什么，
///    所以不做手绘插画。
public struct CorpusRootView: View {
    private let model: CorpusViewModel
    private let onAppear: () -> Void
    private let onRefresh: () -> Void
    private let onLoadMore: () -> Void
    private let onToggleFavorite: (String, Bool) -> Void
    private let onDelete: (String) -> Void
    private let onSearchQueryChanged: (String) -> Void
    private let onFavoriteOnlyChanged: (Bool) -> Void
    private let onSceneFilterChanged: (String?) -> Void
    private let onFunctionFilterChanged: (String?) -> Void
    private let onStartPractice: () -> Void

    /// 哪些卡的对比锚点被**折起来**了。
    ///
    /// 存「折起来的」而不是「展开的」：稿子说锚点**首次展示默认展开**，之后才折叠 ——
    /// 反过来的话，每一条新出现的卡都要先被记一笔才会展开，而那笔记录从哪来都说不清。
    @State private var collapsedAnchorIDs: Set<String> = []

    public init(
        model: CorpusViewModel,
        onAppear: @escaping () -> Void,
        onRefresh: @escaping () -> Void,
        onLoadMore: @escaping () -> Void,
        onToggleFavorite: @escaping (String, Bool) -> Void,
        onDelete: @escaping (String) -> Void,
        onSearchQueryChanged: @escaping (String) -> Void,
        onFavoriteOnlyChanged: @escaping (Bool) -> Void,
        onSceneFilterChanged: @escaping (String?) -> Void = { _ in },
        onFunctionFilterChanged: @escaping (String?) -> Void = { _ in },
        onStartPractice: @escaping () -> Void = {}
    ) {
        self.model = model
        self.onAppear = onAppear
        self.onRefresh = onRefresh
        self.onLoadMore = onLoadMore
        self.onToggleFavorite = onToggleFavorite
        self.onDelete = onDelete
        self.onSearchQueryChanged = onSearchQueryChanged
        self.onFavoriteOnlyChanged = onFavoriteOnlyChanged
        self.onSceneFilterChanged = onSceneFilterChanged
        self.onFunctionFilterChanged = onFunctionFilterChanged
        self.onStartPractice = onStartPractice
    }

    public var body: some View {
        List {
            headerSection

            if let errorMessage = model.errorMessage, !errorMessage.isEmpty {
                Section {
                    Text(errorMessage)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Color.improve)
                }
                .listRowBackground(DesignTokens.Color.background)
            }

            switch model.phase {
            // `.idle` **不是**加载中：它是「服务端回过一次，库里就是空的」。
            // 早先把这两档并在一起，于是空语料库永远停在骨架屏上 —— 一个空库看起来像没加载完。
            // 现在 `.idle` 走到内容区，由投影给出 `noBlocks` 空态（三个形态的进度轴）。
            case .idle:
                contentSection
            case .loading:
                Section {
                    // 稿子 §2.4：加载态用闪光骨架块，不用转圈 —— 形状即说明。
                    ListSkeletonPlaceholder(label: "加载语料库...")
                }
                .listRowBackground(DesignTokens.Color.background)
            case .migrating:
                Section {
                    ListSkeletonPlaceholder(label: "正在迁移语料...")
                }
                .listRowBackground(DesignTokens.Color.background)
            case .failed where model.rows.isEmpty:
                Section {
                    ContentUnavailableView("加载失败", systemImage: "exclamationmark.triangle")
                    Button("重试") { onRefresh() }
                }
                .listRowBackground(DesignTokens.Color.background)
            case .ready, .failed:
                contentSection
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(DesignTokens.Color.background)
        .navigationTitle("语料库")
        // 稿子 屏 08 没有工具栏，也没有「刷新」这个按钮 —— 刷新是下拉手势（系统自带、无需发明）。
        // 原来那个 ToolbarItem 是自造的：它占着右上角，而稿子那里什么都没有。
        .refreshable { onRefresh() }
        .overlay(alignment: .bottom) {
            if model.isRefreshing, model.phase == .ready {
                ProgressView()
                    .padding(.bottom, 12)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.isReplayingOutbox {
                Text("正在同步离线操作...")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
                    .padding(.vertical, DesignTokens.Spacing.s2)
            }
        }
        .task { onAppear() }
    }

    // MARK: - 头部：计数 ＋ 检索 ＋ 两个维度

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.s3) {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.s2) {
                    Text(model.blockCountLabel)
                        .font(DesignTokens.Typography.cardTitle)
                        .foregroundStyle(DesignTokens.Color.textPrimary)
                    if model.showsUnloadedNote {
                        Text("（还有更多没加载）")
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.Color.textSecondary)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: DesignTokens.Spacing.s2) {
                    DesignTokens.Icon.search.image
                        .font(.system(size: DesignTokens.Component.iconPointSize * 0.75))
                        .foregroundStyle(DesignTokens.Color.textSecondary)

                    TextField(
                        "搜索意图 / 英文 / 锚点",
                        text: Binding(
                            get: { model.searchQuery },
                            set: onSearchQueryChanged
                        )
                    )
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Color.textPrimary)

                    Button {
                        onFavoriteOnlyChanged(!model.favoriteOnly)
                    } label: {
                        Text("收藏")
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(
                                model.favoriteOnly
                                    ? DesignTokens.Color.textPrimary
                                    : DesignTokens.Color.textSecondary
                            )
                            .padding(.horizontal, DesignTokens.Spacing.s3)
                            .padding(.vertical, DesignTokens.Spacing.s1)
                            .background(
                                model.favoriteOnly
                                    ? DesignTokens.Color.brand
                                    : DesignTokens.Color.backgroundElevated,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("corpus.filter.favorite")
                }
                .padding(.horizontal, DesignTokens.Spacing.s3)
                .padding(.vertical, DesignTokens.Spacing.s2)
                .background(
                    DesignTokens.Color.backgroundElevated,
                    in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                )

                chipRow(
                    title: "场景",
                    chips: model.sceneOptions,
                    identifierPrefix: "corpus.filter.scene",
                    onSelect: onSceneFilterChanged
                )
                chipRow(
                    title: "功能",
                    chips: model.functionOptions,
                    identifierPrefix: "corpus.filter.function",
                    onSelect: onFunctionFilterChanged
                )
            }
            .padding(.vertical, DesignTokens.Spacing.s2)
        }
        .listRowSeparator(.hidden)
        .listRowBackground(DesignTokens.Color.background)
    }

    /// 一排横向滚动的 chips。**点已选中的那一个就是取消** —— 所以这里不另做一枚「全部」：
    /// 那会让「取消」有两个入口，而它们的行为得一模一样才不会出错。
    private func chipRow(
        title: String,
        chips: [CorpusViewModel.FilterChip],
        identifierPrefix: String,
        onSelect: @escaping (String?) -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.s2) {
            Text(title)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Color.textSecondary)
                .frame(width: 28, alignment: .leading)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DesignTokens.Spacing.s2) {
                    ForEach(chips) { chip in
                        Button {
                            onSelect(chip.isSelected ? nil : chip.id)
                        } label: {
                            Text(chip.title)
                                .font(DesignTokens.Typography.caption)
                                .foregroundStyle(
                                    chip.isSelected
                                        ? DesignTokens.Color.textPrimary
                                        : DesignTokens.Color.textSecondary
                                )
                                .padding(.horizontal, DesignTokens.Spacing.s3)
                                .padding(.vertical, DesignTokens.Spacing.s1)
                                .background(
                                    chip.isSelected
                                        ? DesignTokens.Color.brand
                                        : DesignTokens.Color.backgroundElevated,
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("\(identifierPrefix).\(chip.id)")
                        .accessibilityAddTraits(chip.isSelected ? [.isSelected] : [])
                    }
                }
            }
        }
    }

    // MARK: - 列表 / 空态

    @ViewBuilder
    private var contentSection: some View {
        if let emptyState = model.emptyState {
            Section {
                switch emptyState {
                case .noBlocks:
                    CorpusEmptyAxisView(onStartPractice: onStartPractice)
                case .noMatches:
                    ContentUnavailableView(
                        "没有匹配的话术块",
                        systemImage: "magnifyingglass",
                        description: Text("换一个筛选条件，或清掉搜索词。")
                    )
                }
            }
            .listRowSeparator(.hidden)
            .listRowBackground(DesignTokens.Color.background)
        } else {
            Section {
                ForEach(model.rows) { row in
                    card(row)
                        .listRowInsets(
                            EdgeInsets(
                                top: DesignTokens.Spacing.s2,
                                leading: DesignTokens.Spacing.pageMargin,
                                bottom: DesignTokens.Spacing.s2,
                                trailing: DesignTokens.Spacing.pageMargin
                            )
                        )
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(row.isFavorite ? "取消收藏" : "收藏") {
                                onToggleFavorite(row.id, !row.isFavorite)
                            }
                            .tint(DesignTokens.Color.brand)

                            Button("删除", role: .destructive) {
                                onDelete(row.id)
                            }
                        }
                }

                if model.canLoadMore {
                    Button(model.isRefreshing ? "加载中..." : "加载更多") { onLoadMore() }
                        .disabled(model.isRefreshing)
                        .listRowBackground(DesignTokens.Color.background)
                }
            }
            .listRowBackground(DesignTokens.Color.background)
        }
    }

    /// 三段式卡片。
    private func card(_ row: CorpusRowViewData) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s2) {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.s2) {
                Text(row.intentZH)
                    .font(DesignTokens.Typography.cardTitle)
                    .foregroundStyle(DesignTokens.Color.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if row.isFavorite {
                    DesignTokens.Icon.star4.image
                        .font(.system(size: DesignTokens.Component.iconPointSize * 0.6))
                        .foregroundStyle(DesignTokens.Color.accent)
                }

                if let lamp = row.lamp {
                    Image(systemName: lamp.form.symbolName)
                        .font(.system(size: DesignTokens.Component.statusDotDiameter))
                        .foregroundStyle(DesignTokens.Color.color(forHex: lamp.colorHex))
                        .accessibilityLabel(lamp.accessibilityLabel)
                }
            }

            Text(row.expressionEN)
                .font(DesignTokens.Typography.englishPhrase)
                .foregroundStyle(DesignTokens.Color.accent)
                .textSelection(.enabled)

            if let realUseNote = row.realUseNote {
                Text(realUseNote)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Color.success)
            }

            anchor(row)

            HStack(spacing: DesignTokens.Spacing.s2) {
                if let scene = row.sceneLabel {
                    tag(scene)
                }
                if let function = row.functionLabel {
                    tag(function)
                }
                Spacer(minLength: 0)
                if row.hasPendingFavorite || row.hasPendingDelete {
                    Text(row.hasPendingDelete ? "待同步删除" : "待同步收藏")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Color.training)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Spacing.s3)
        .background(
            DesignTokens.Color.backgroundElevated,
            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
        )
    }

    /// 对比锚点：可折叠，**默认展开**。
    @ViewBuilder
    private func anchor(_ row: CorpusRowViewData) -> some View {
        let isCollapsed = collapsedAnchorIDs.contains(row.id)

        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s1) {
            Button {
                if isCollapsed {
                    collapsedAnchorIDs.remove(row.id)
                } else {
                    collapsedAnchorIDs.insert(row.id)
                }
            } label: {
                HStack(spacing: DesignTokens.Spacing.s1) {
                    Text("你当时说")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                    Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                        .font(.caption2)
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("corpus.anchor.toggle.\(row.id)")

            if !isCollapsed {
                Text(row.anchorUserSaid)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
            }
        }
    }

    private func tag(_ title: String) -> some View {
        Text(title)
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.Color.textSecondary)
            .padding(.horizontal, DesignTokens.Spacing.s2)
            .padding(.vertical, 2)
            .background(DesignTokens.Color.wash, in: Capsule())
    }
}

/// 首次进入的空态：**用状态灯的三个形态纵向排成一条进度轴**（稿子 屏 08）。
///
/// 不做手绘插画是有理由的：这三个形态就是这一屏接下来会长出来的东西，
/// 图形本身在说明「这里会发生什么」—— 一张插画说明的是别的事。
private struct CorpusEmptyAxisView: View {
    let onStartPractice: () -> Void

    private let stages: [(CorpusStateLamp, String)] = [
        (.new, "新入库"),
        (.training, "训练中"),
        (.automated, "已自动化"),
    ]

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.s4) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.s3) {
                ForEach(stages, id: \.0) { lamp, title in
                    HStack(spacing: DesignTokens.Spacing.s3) {
                        Image(systemName: lamp.form.symbolName)
                            .font(.system(size: DesignTokens.Component.statusDotDiameter + 2))
                            .foregroundStyle(DesignTokens.Color.color(forHex: lamp.colorHex))
                            .accessibilityHidden(true)

                        Text(title)
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.Color.textSecondary)
                    }
                }
            }
            .padding(.vertical, DesignTokens.Spacing.s2)

            Text("完成第一次对话练习，这里就会长出你的第一批表达")
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Color.textSecondary)
                .multilineTextAlignment(.center)

            Button(action: onStartPractice) {
                Text("去练习")
                    .font(DesignTokens.Typography.cardTitle)
                    .foregroundStyle(DesignTokens.Color.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: DesignTokens.Component.minHitTarget)
                    .background(
                        DesignTokens.Color.brandStrong,
                        in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("corpus.empty.startPractice")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignTokens.Spacing.s6)
        .accessibilityElement(children: .contain)
    }
}
