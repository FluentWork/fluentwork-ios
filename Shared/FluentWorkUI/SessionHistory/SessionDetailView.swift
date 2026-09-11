import SwiftUI

public enum SessionDetailViewPhase: Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed
}

public struct SessionDetailTurnViewData: Equatable, Sendable, Identifiable {
    public var id: Int
    public var isUser: Bool
    public var speakerLabel: String
    public var text: String

    public init(id: Int, isUser: Bool, speakerLabel: String, text: String) {
        self.id = id
        self.isUser = isUser
        self.speakerLabel = speakerLabel
        self.text = text
    }
}

public struct SessionDetailViewModel: Equatable, Sendable {
    public var phase: SessionDetailViewPhase
    /// `今天 14:32 · 2 分 34 秒` — the header line, built by
    /// `SessionHistoryFormatting` like everything else here.
    public var subtitleText: String
    public var turns: [SessionDetailTurnViewData]
    public var errorMessage: String?

    /// Whether there is anything worth carrying into a new session.
    ///
    /// A session that was opened and closed without a word has no transcript,
    /// and offering to continue from it would open a room whose first line is
    /// as generic as if nothing had been asked for — the button would be
    /// promising something it cannot deliver.
    public var canContinue: Bool { !turns.isEmpty }

    public init(
        phase: SessionDetailViewPhase,
        subtitleText: String = "",
        turns: [SessionDetailTurnViewData] = [],
        errorMessage: String? = nil
    ) {
        self.phase = phase
        self.subtitleText = subtitleText
        self.turns = turns
        self.errorMessage = errorMessage
    }
}

/// One past session's transcript, and the way back into a new one.
///
/// This is what makes the list worth opening: without it a row says "2 分 34 秒"
/// and nothing else.
///
/// **The transcript is read-only, and 从这一场继续 does not reopen it.** The
/// server cannot resume a session (`79_` §约束 1), so continuing means opening a
/// *new* one that has been told what the old one was about — the id goes to the
/// server, the server decides whether it may be read, and the model opens by
/// picking the thread back up. Nothing here replays the old turns into the new
/// room, and nothing here can.
public struct SessionDetailView: View {
    private let model: SessionDetailViewModel
    private let onAppear: () -> Void
    private let onRetry: () -> Void
    private let onContinue: () -> Void

    public init(
        model: SessionDetailViewModel,
        onAppear: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        onContinue: @escaping () -> Void
    ) {
        self.model = model
        self.onAppear = onAppear
        self.onRetry = onRetry
        self.onContinue = onContinue
    }

    public var body: some View {
        List {
            switch model.phase {
            case .idle, .loading:
                Section {
                    ProgressView("加载对话记录...")
                }

            case .failed:
                Section {
                    ContentUnavailableView(
                        "加载失败",
                        systemImage: "exclamationmark.triangle",
                        description: Text(model.errorMessage ?? "检查网络后重试。")
                    )
                    Button("重试") {
                        onRetry()
                    }
                }

            case .ready:
                Section {
                    if !model.subtitleText.isEmpty {
                        Text(model.subtitleText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        onContinue()
                    } label: {
                        Label("从这一场继续", systemImage: "arrow.uturn.forward.circle")
                    }
                    .disabled(!model.canContinue)
                }

                if !model.canContinue {
                    Section {
                        Text("这一场没有留下对话，没有可以接着聊的内容。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    if model.turns.isEmpty {
                        ContentUnavailableView(
                            "这一场没有留下对话",
                            systemImage: "bubble.left",
                            description: Text("会话建立了但没有说完任何一轮。")
                        )
                    } else {
                        ForEach(model.turns) { turn in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(turn.speakerLabel)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(turn.isUser ? .primary : .secondary)
                                Text(turn.text)
                                    .foregroundStyle(turn.isUser ? .primary : .secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
        .navigationTitle("这一场")
        .task {
            onAppear()
        }
    }
}
