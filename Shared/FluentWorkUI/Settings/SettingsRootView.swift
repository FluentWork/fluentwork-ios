import SwiftUI

/// What the settings screen shows. Plain data on purpose: this module has never
/// depended on the feature-flag types, and the host maps state into this — the
/// same split `ReviewViewModel` uses.
public struct SettingsViewModel: Equatable, Sendable {
    public struct FlagRow: Identifiable, Equatable, Sendable {
        /// The flag's raw value. A `String` rather than the enum so this module
        /// stays free of `FluentWorkFeatureFlags`; the host maps it back, and
        /// the round trip is lossless because the enum is `String`-backed.
        public let id: String
        public let title: String
        public let isEnabled: Bool
        /// Whether the current value comes from a local override rather than
        /// the build's defaults. Worth showing: an override is what the device
        /// test turns on and forgets to turn off, and the two look identical
        /// without it.
        public let isOverridden: Bool

        public init(id: String, title: String, isEnabled: Bool, isOverridden: Bool) {
            self.id = id
            self.title = title
            self.isEnabled = isEnabled
            self.isOverridden = isOverridden
        }
    }

    public var flags: [FlagRow]
    public var appVersion: String
    public var hasOverrides: Bool
    /// 屏 12 的那几组（账号 / 语音偏好 / 隐私与数据）。
    public var sceneRows: SceneRows?

    public init(
        flags: [FlagRow],
        appVersion: String,
        hasOverrides: Bool,
        sceneRows: SceneRows? = nil
    ) {
        self.flags = flags
        self.appVersion = appVersion
        self.hasOverrides = hasOverrides
        self.sceneRows = sceneRows
    }

    public static let empty = SettingsViewModel(flags: [], appVersion: "", hasOverrides: false)
}

/// The settings screen.
///
/// A real product surface, not a debug menu — the PRD's information
/// architecture already has one (G2, AI speech rate, lands here). The feature
/// flags live in a section that only exists in **DEBUG builds**, so what ships
/// is a settings page with nothing experimental in it.
///
/// Reachable without a flag gating it, deliberately: every other surface is a
/// `FeaturePluginDescriptor` filtered by its own flag, and a settings page
/// behind a flag could only be opened by someone who had already turned that
/// flag on — which is the one thing it exists to let you do.
public struct SettingsRootView: View {
    private let model: SettingsViewModel
    private let onToggleFlag: (String, Bool) -> Void
    private let onClearOverrides: () -> Void
    /// 「删除我的全部素材」三步：按下 → 确认 → 真的删。
    ///
    /// 三个回调而不是一个布尔：**「按下」不等于「确认」**，中间那一步是这一屏存在的理由
    /// （稿子：「二次确认后才执行」）。
    private let onDeleteTapped: () -> Void
    private let onDeleteConfirmed: () -> Void
    private let onDeleteCancelled: () -> Void

    @State private var isShowingDeleteConfirmation = false

    public init(
        model: SettingsViewModel,
        onToggleFlag: @escaping (String, Bool) -> Void,
        onClearOverrides: @escaping () -> Void,
        onDeleteTapped: @escaping () -> Void = {},
        onDeleteConfirmed: @escaping () -> Void = {},
        onDeleteCancelled: @escaping () -> Void = {}
    ) {
        self.model = model
        self.onToggleFlag = onToggleFlag
        self.onClearOverrides = onClearOverrides
        self.onDeleteTapped = onDeleteTapped
        self.onDeleteConfirmed = onDeleteConfirmed
        self.onDeleteCancelled = onDeleteCancelled
    }

    public var body: some View {
        List {
            if let rows = model.sceneRows {
                accountSection(rows)
                voiceSection(rows)
                privacySection(rows)
            }
            aboutSection
            #if DEBUG
                developerSection
            #endif
        }
        .navigationTitle("设置")
        .alert(
            model.sceneRows?.deleteFlow.confirmationTitle ?? "删除我的全部素材？",
            isPresented: $isShowingDeleteConfirmation
        ) {
            Button(model.sceneRows?.deleteFlow.confirmButtonTitle ?? "删除", role: .destructive) {
                onDeleteConfirmed()
            }
            Button(model.sceneRows?.deleteFlow.cancelButtonTitle ?? "取消", role: .cancel) {
                onDeleteCancelled()
            }
        } message: {
            Text(model.sceneRows?.deleteFlow.confirmationMessage ?? "")
        }
    }

    // MARK: - 屏 12 的三组

    private func accountSection(_ rows: SettingsViewModel.SceneRows) -> some View {
        Section("账号") {
            infoRow(rows.account)
        }
    }

    private func voiceSection(_ rows: SettingsViewModel.SceneRows) -> some View {
        Section("语音偏好") {
            ForEach(rows.voice) { row in
                infoRow(row)
            }
        }
    }

    private func privacySection(_ rows: SettingsViewModel.SceneRows) -> some View {
        Section {
            ForEach(rows.privacy.filter { $0.id != "privacy.delete" }) { row in
                infoRow(row)
            }
            deleteRow(rows.deleteFlow)
        } header: {
            Text("隐私与数据")
        } footer: {
            // 回执与失败都写在这一组的脚下：**它们是这一组的结果**，
            // 弹窗关掉之后就没了，而「删掉了多少」这件事值得留在屏幕上。
            if let result = rows.deleteFlow.resultMessage {
                Text(result)
            } else if let error = rows.deleteFlow.errorMessage {
                Text(error)
            }
        }
    }

    private func infoRow(_ row: SettingsInfoRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(row.title)
                if row.hasDisclosure {
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            if let detail = row.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 「删除我的全部素材」：**待改进色，不是纯红**（稿子原话，与全局色彩纪律一致）。
    @ViewBuilder
    private func deleteRow(_ flow: SettingsDeleteFlow) -> some View {
        Button {
            onDeleteTapped()
            isShowingDeleteConfirmation = true
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("删除我的全部素材")
                        .foregroundStyle(DesignTokens.Color.improve)
                    Text(flow.isDeleting ? "正在删除…" : "二次确认后即时生效，并级联删除衍生的话术块")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if flow.isDeleting {
                    ProgressView().progressViewStyle(.circular)
                }
            }
        }
        .disabled(flow.canDelete == false)
        // **`.plain` 不是为了好看**：`List` 里的 `Button` 会把整个 label 染成强调色，
        // 于是那一行说明文字变成蓝的（截图里抓到的），而行内两种颜色各有各的意思 ——
        // 标题是「待改进色」（这是要小心的一步），说明是次要灰（这是在说什么事）。
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.deleteAllMaterials")
    }

    // MARK: - 关于 / 开发者

    private var aboutSection: some View {
        Section("关于") {
            LabeledContent("版本", value: model.appVersion)
        }
    }

    #if DEBUG
        private var developerSection: some View {
            Section {
                ForEach(model.flags) { row in
                    Toggle(isOn: binding(for: row)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                            if row.isOverridden {
                                Text("已被本地覆盖")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // The escape hatch a device run needs. An override set on a
                // phone outlives the test that set it, and there is no other
                // way back to the build's defaults short of reinstalling.
                Button("清除全部本地覆盖", role: .destructive) {
                    onClearOverrides()
                }
                .disabled(!model.hasOverrides)
            } header: {
                Text("开发者")
            } footer: {
                Text("本地覆盖只影响这台设备，不会写进版本库。真机验证需要开关的实验性能力时用它。")
            }
        }

        private func binding(for row: SettingsViewModel.FlagRow) -> Binding<Bool> {
            Binding(
                get: { row.isEnabled },
                set: { onToggleFlag(row.id, $0) }
            )
        }
    #endif
}
