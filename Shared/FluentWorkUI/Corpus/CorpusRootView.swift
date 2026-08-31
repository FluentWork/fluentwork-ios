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
    public var isFavorite: Bool
    public var hasPendingFavorite: Bool
    public var hasPendingDelete: Bool
    public var updatedAt: String

    public init(
        id: String,
        intentZH: String,
        expressionEN: String,
        anchorUserSaid: String,
        sceneTag: String,
        functionTag: String,
        isFavorite: Bool,
        hasPendingFavorite: Bool = false,
        hasPendingDelete: Bool = false,
        updatedAt: String
    ) {
        self.id = id
        self.intentZH = intentZH
        self.expressionEN = expressionEN
        self.anchorUserSaid = anchorUserSaid
        self.sceneTag = sceneTag
        self.functionTag = functionTag
        self.isFavorite = isFavorite
        self.hasPendingFavorite = hasPendingFavorite
        self.hasPendingDelete = hasPendingDelete
        self.updatedAt = updatedAt
    }
}

public struct CorpusViewModel: Equatable, Sendable {
    public var phase: CorpusViewPhase
    public var rows: [CorpusRowViewData]
    public var searchQuery: String
    public var favoriteOnly: Bool
    public var isRefreshing: Bool
    public var isReplayingOutbox: Bool
    public var canLoadMore: Bool
    public var errorMessage: String?

    public init(
        phase: CorpusViewPhase,
        rows: [CorpusRowViewData] = [],
        searchQuery: String = "",
        favoriteOnly: Bool = false,
        isRefreshing: Bool = false,
        isReplayingOutbox: Bool = false,
        canLoadMore: Bool = false,
        errorMessage: String? = nil
    ) {
        self.phase = phase
        self.rows = rows
        self.searchQuery = searchQuery
        self.favoriteOnly = favoriteOnly
        self.isRefreshing = isRefreshing
        self.isReplayingOutbox = isReplayingOutbox
        self.canLoadMore = canLoadMore
        self.errorMessage = errorMessage
    }
}

public struct CorpusRootView: View {
    private let model: CorpusViewModel
    private let onAppear: () -> Void
    private let onRefresh: () -> Void
    private let onLoadMore: () -> Void
    private let onToggleFavorite: (String, Bool) -> Void
    private let onDelete: (String) -> Void
    private let onSearchQueryChanged: (String) -> Void
    private let onFavoriteOnlyChanged: (Bool) -> Void

    public init(
        model: CorpusViewModel,
        onAppear: @escaping () -> Void,
        onRefresh: @escaping () -> Void,
        onLoadMore: @escaping () -> Void,
        onToggleFavorite: @escaping (String, Bool) -> Void,
        onDelete: @escaping (String) -> Void,
        onSearchQueryChanged: @escaping (String) -> Void,
        onFavoriteOnlyChanged: @escaping (Bool) -> Void
    ) {
        self.model = model
        self.onAppear = onAppear
        self.onRefresh = onRefresh
        self.onLoadMore = onLoadMore
        self.onToggleFavorite = onToggleFavorite
        self.onDelete = onDelete
        self.onSearchQueryChanged = onSearchQueryChanged
        self.onFavoriteOnlyChanged = onFavoriteOnlyChanged
    }

    public var body: some View {
        List {
            Section {
                TextField(
                    "搜索 intent / expression / anchor",
                    text: Binding(
                        get: { model.searchQuery },
                        set: { newValue in
                            onSearchQueryChanged(newValue)
                        }
                    )
                )
                Toggle(
                    "只看收藏",
                    isOn: Binding(
                        get: { model.favoriteOnly },
                        set: { newValue in
                            onFavoriteOnlyChanged(newValue)
                        }
                    )
                )
            }

            if let errorMessage = model.errorMessage, !errorMessage.isEmpty {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            switch model.phase {
            case .idle:
                Section {
                    ContentUnavailableView("语料库为空", systemImage: "books.vertical")
                }
            case .loading:
                Section {
                    ProgressView("加载语料库...")
                }
            case .migrating:
                Section {
                    ProgressView("正在迁移语料...")
                }
            case .failed where model.rows.isEmpty:
                Section {
                    ContentUnavailableView("加载失败", systemImage: "exclamationmark.triangle")
                    Button("重试") {
                        onRefresh()
                    }
                }
            case .ready, .failed:
                Section {
                    if model.rows.isEmpty {
                        ContentUnavailableView("没有匹配结果", systemImage: "magnifyingglass")
                    } else {
                        ForEach(model.rows) { row in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(row.intentZH)
                                        .font(.headline)
                                    Spacer()
                                    if row.isFavorite {
                                        Image(systemName: "star.fill")
                                            .foregroundStyle(.yellow)
                                    }
                                }
                                Text(row.expressionEN)
                                Text(row.anchorUserSaid)
                                    .foregroundStyle(.secondary)
                                if row.hasPendingFavorite || row.hasPendingDelete {
                                    Text(row.hasPendingDelete ? "待同步删除" : "待同步收藏")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                                HStack {
                                    Text(row.sceneTag)
                                    Text("·")
                                    Text(row.functionTag)
                                    Spacer()
                                    Text(row.updatedAt)
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(row.isFavorite ? "取消收藏" : "收藏") {
                                    onToggleFavorite(row.id, !row.isFavorite)
                                }
                                .tint(.yellow)

                                Button("删除", role: .destructive) {
                                    onDelete(row.id)
                                }
                            }
                        }

                        if model.canLoadMore {
                            Button(model.isRefreshing ? "加载中..." : "加载更多") {
                                onLoadMore()
                            }
                            .disabled(model.isRefreshing)
                        }
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if model.isRefreshing, model.phase == .ready {
                ProgressView()
                    .padding(.bottom, 12)
            }
        }
        .toolbar {
            ToolbarItem {
                Button("刷新") {
                    onRefresh()
                }
                .disabled(model.isRefreshing)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.isReplayingOutbox {
                Text("正在同步离线操作...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
        .task {
            onAppear()
        }
    }
}
