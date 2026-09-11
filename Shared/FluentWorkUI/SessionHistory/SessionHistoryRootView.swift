import SwiftUI

public enum SessionHistoryViewPhase: Equatable, Sendable {
    case idle
    case loading
    case ready
    case empty
    case failed
}

/// One row. All text, no dates — `FluentWorkUI` formats nothing, and the
/// strings arrive already built from `SessionHistoryFormatting`.
///
/// There is no title field yet, and its absence is the list's known gap: the
/// contract (`backend internal/sessionhistory/model.go`) carries only
/// `session_id / scene_type / status / started_at / duration_sec /
/// material_id`, none of which a person can recognise a conversation by. The
/// row therefore leads with *when* and *how long*, which is the most a reader
/// can go on until the backend adds a title (`79_` §约束 3). Add the field
/// here and in the row at the same time as the contract.
public struct SessionHistoryRowViewData: Equatable, Sendable, Identifiable {
    public var id: String
    public var startedAtText: String
    public var durationText: String
    public var statusText: String

    public init(
        id: String,
        startedAtText: String,
        durationText: String,
        statusText: String
    ) {
        self.id = id
        self.startedAtText = startedAtText
        self.durationText = durationText
        self.statusText = statusText
    }
}

public struct SessionHistoryViewModel: Equatable, Sendable {
    public var phase: SessionHistoryViewPhase
    public var rows: [SessionHistoryRowViewData]
    public var canLoadMore: Bool
    public var isLoadingMore: Bool
    public var errorMessage: String?

    public init(
        phase: SessionHistoryViewPhase,
        rows: [SessionHistoryRowViewData] = [],
        canLoadMore: Bool = false,
        isLoadingMore: Bool = false,
        errorMessage: String? = nil
    ) {
        self.phase = phase
        self.rows = rows
        self.canLoadMore = canLoadMore
        self.isLoadingMore = isLoadingMore
        self.errorMessage = errorMessage
    }
}

/// The conversation list.
///
/// A row opens **that session's transcript** (`SessionDetailView`), pushed onto
/// the same stack. It deliberately does *not* open the speaking room: the server
/// cannot resume a session (`79_` §约束 1), so a row that dropped the user into
/// the room would land them in an empty one — which is the exact complaint this
/// list exists to answer.
public struct SessionHistoryRootView: View {
    private let model: SessionHistoryViewModel
    private let onAppear: () -> Void
    private let onRefresh: () -> Void
    private let onLoadMore: () -> Void
    private let onSelect: (String) -> Void

    public init(
        model: SessionHistoryViewModel,
        onAppear: @escaping () -> Void,
        onRefresh: @escaping () -> Void,
        onLoadMore: @escaping () -> Void,
        onSelect: @escaping (String) -> Void
    ) {
        self.model = model
        self.onAppear = onAppear
        self.onRefresh = onRefresh
        self.onLoadMore = onLoadMore
        self.onSelect = onSelect
    }

    public var body: some View {
        List {
            if let errorMessage = model.errorMessage, !errorMessage.isEmpty {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            switch model.phase {
            case .idle, .loading:
                Section {
                    ProgressView("加载练习历史...")
                }

            case .empty:
                Section {
                    ContentUnavailableView(
                        "还没有练习记录",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("完成一次练习后，这里会出现它的时间与时长。")
                    )
                }

            case .failed:
                Section {
                    ContentUnavailableView(
                        "加载失败",
                        systemImage: "exclamationmark.triangle",
                        description: Text("检查网络后重试。")
                    )
                    Button("重试") {
                        onRefresh()
                    }
                }

            case .ready:
                Section {
                    ForEach(model.rows) { row in
                        Button {
                            onSelect(row.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.startedAtText)
                                    .font(.headline)
                                HStack(spacing: 6) {
                                    Text(row.durationText)
                                    Text("·")
                                    Text(row.statusText)
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    if model.canLoadMore {
                        Button(model.isLoadingMore ? "加载中..." : "加载更多") {
                            onLoadMore()
                        }
                        .disabled(model.isLoadingMore)
                    }
                }
            }

            Section {
                Text("点开任意一场可以看到当时的对话。要接着那场继续聊，得另开一场新的 —— 服务端不保存可以续接的会话。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("练习历史")
        .toolbar {
            ToolbarItem {
                Button("刷新") {
                    onRefresh()
                }
                .disabled(model.isLoadingMore)
            }
        }
        .overlay(alignment: .bottom) {
            if model.isLoadingMore, model.phase == .ready {
                ProgressView()
                    .padding(.bottom, 12)
            }
        }
        .task {
            onAppear()
        }
    }
}
