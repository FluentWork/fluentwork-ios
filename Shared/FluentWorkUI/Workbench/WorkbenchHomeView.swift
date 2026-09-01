import SwiftUI

public struct WorkbenchHomeViewModel: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case loading
        case ready
        case empty
        case failed(message: String?)
    }

    public struct Module: Equatable, Sendable, Identifiable {
        public enum Kind: String, Equatable, Sendable {
            case speakingRoom
            case review
            case dailyRead
            case unsupported
        }

        public let id: String
        public let title: String
        public let subtitle: String
        public let systemImage: String
        public let entryRoute: String
        public let kind: Kind
        public let isAvailable: Bool

        public init(
            id: String,
            title: String,
            subtitle: String,
            systemImage: String,
            entryRoute: String,
            kind: Kind,
            isAvailable: Bool = true
        ) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.systemImage = systemImage
            self.entryRoute = entryRoute
            self.kind = kind
            self.isAvailable = isAvailable
        }
    }

    public var phase: Phase
    public var modules: [Module]
    public var isOffline: Bool
    public var activeModuleTitle: String?
    public var highlightedBadge: String?
    public var badgeFeedCount: Int

    public init(
        phase: Phase,
        modules: [Module] = [],
        isOffline: Bool = false,
        activeModuleTitle: String? = nil,
        highlightedBadge: String? = nil,
        badgeFeedCount: Int = 0
    ) {
        self.phase = phase
        self.modules = modules
        self.isOffline = isOffline
        self.activeModuleTitle = activeModuleTitle
        self.highlightedBadge = highlightedBadge
        self.badgeFeedCount = badgeFeedCount
    }

    public var statusTitle: String {
        switch phase {
        case .loading:
            return "正在准备工作台"
        case .ready:
            return "开始今天的练习"
        case .empty:
            return "当前没有可用模块"
        case .failed:
            return "工作台加载失败"
        }
    }

    public var statusDetail: String {
        switch phase {
        case .loading:
            return "正在同步启动配置和可见模块。"
        case .ready:
            return "按模块进入练习流，导航统一走 TGNavigation。"
        case .empty:
            return "当前环境下没有开放模块，稍后重试。"
        case let .failed(message):
            return message ?? "启动配置拉取失败，请重新触发 bootstrap。"
        }
    }

    public var showsRetryAction: Bool {
        if case .failed = phase {
            return true
        }
        return false
    }
}

public struct WorkbenchHomeView: View {
    private let model: WorkbenchHomeViewModel
    private let onModuleTapped: (WorkbenchHomeViewModel.Module) -> Void
    private let onRetryTapped: () -> Void

    public init(
        model: WorkbenchHomeViewModel,
        onModuleTapped: @escaping (WorkbenchHomeViewModel.Module) -> Void,
        onRetryTapped: @escaping () -> Void = {}
    ) {
        self.model = model
        self.onModuleTapped = onModuleTapped
        self.onRetryTapped = onRetryTapped
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusCard

                if !model.modules.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("功能入口")
                            .font(.headline)

                        ForEach(model.modules) { module in
                            moduleButton(module)
                        }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("工作台")
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.statusTitle)
                    .font(.title3.weight(.semibold))

                Spacer(minLength: 12)

                if model.isOffline {
                    Label("离线", systemImage: "wifi.slash")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            Text(model.statusDetail)
                .foregroundStyle(.secondary)

            if case .loading = model.phase {
                ProgressView()
            }

            if let activeModuleTitle = model.activeModuleTitle {
                infoPill(title: "当前入口", value: activeModuleTitle)
            }

            if let highlightedBadge = model.highlightedBadge, !highlightedBadge.isEmpty {
                infoPill(title: "最近反馈", value: highlightedBadge)
            }

            if model.badgeFeedCount > 0 {
                infoPill(title: "反馈次数", value: "\(model.badgeFeedCount)")
            }

            if model.showsRetryAction {
                Button("重新加载") {
                    onRetryTapped()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func moduleButton(_ module: WorkbenchHomeViewModel.Module) -> some View {
        Button {
            onModuleTapped(module)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: module.systemImage)
                    .font(.title3)
                    .foregroundStyle(module.isAvailable ? Color.accentColor : Color.secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(module.title)
                            .font(.headline)
                            .foregroundStyle(.primary)

                        Text(presentationLabel(for: module.kind))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                    Text(module.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 12)

                Image(systemName: module.isAvailable ? "chevron.right" : "lock")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!module.isAvailable)
        .accessibilityIdentifier("workbench.module.\(module.id)")
    }

    private func infoPill(title: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.1))
        .clipShape(Capsule())
    }

    private func presentationLabel(for kind: WorkbenchHomeViewModel.Module.Kind) -> String {
        switch kind {
        case .speakingRoom, .review:
            return "全屏"
        case .dailyRead:
            return "页内"
        case .unsupported:
            return "未开放"
        }
    }
}
