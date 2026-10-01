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
/// **它是全屏页，不是 tab**（稿子 §03：设置与说的房间/回顾页/每日一读/话题建议同属
/// 「全屏页（从入口推入）」），所以它自己带 `.fullScreenPage()`。
///
/// 版式按稿子 屏 12 的 `set-group` / `set-row` 几何还原 —— 每一行是**一张独立的圆角卡**，
/// 而不是 iOS 分组列表那种带分隔线的整块表：
///
/// | 稿子 | 数值 |
/// |---|---|
/// | `.set-row` | `padding: 13px 15px`，`gap: 12px`，圆角 `--fw-r-card` = 12，底 `--fw-bg-elev` |
/// | `.set-row + .set-row` | 行间 8px（**卡与卡之间留缝，不是画线**） |
/// | `.sr-ico` | 30×30、圆角 9、底为强调色 13%，图标 17px 用强调色 |
/// | `.sr-body b` / `span` | 标题 14.5/600；说明 12、次要色 |
/// | `.set-group > h3` | 组标题 12px、次要色 |
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
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.s6) {
                if let rows = model.sceneRows {
                    group("账号") {
                        infoCard(rows.account)
                    }
                    group("语音偏好") {
                        ForEach(rows.voice) { infoCard($0) }
                    }
                    group("隐私与数据") {
                        ForEach(rows.privacy.filter { $0.id != "privacy.delete" }) { infoCard($0) }
                        deleteCard(
                            rows.deleteFlow,
                            icon: rows.privacy.first { $0.id == "privacy.delete" }?.icon
                        )
                    }
                }
                group("关于") {
                    versionCard
                }
                #if DEBUG
                    developerGroup
                #endif
            }
            .padding(.horizontal, DesignTokens.Spacing.pageMargin)
            .padding(.vertical, DesignTokens.Spacing.s4)
        }
        .background(DesignTokens.Color.background)
        // 稿子 §03：「全屏页（从入口推入）」—— 推入这件事由导航栈做，
        // **盖住底部 tab bar** 这一条由这个修饰符补齐（否则只是半个全屏页）。
        .fullScreenPage()
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

    // MARK: - 版式的三块（组 / 卡 / 图标方块）

    /// 一组：组标题（12px 次要色）＋ 若干张卡（卡间 8px，稿子 `.set-row + .set-row`）。
    private func group<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s2) {
            Text(title)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Color.textSecondary)
            VStack(spacing: DesignTokens.Spacing.s2) {
                content()
            }
        }
    }

    /// 一张卡：`padding 13×15`、圆角 12、底 `bg-elev`。
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: DesignTokens.Spacing.s3) {
            content()
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.Color.backgroundElevated)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous))
    }

    /// 行首图标：**30×30 的圆角方块**，底为强调色 13%，图标用强调色（稿子 `.sr-ico`）。
    ///
    /// 它不是「裸图标」——这是我第一版的错处之一：一个灰色的裸图标和一枚带底的方块，
    /// 在列表里的分量完全不同（后者是这一行的身份，前者只是一个记号）。
    private func iconChip(_ icon: DesignTokens.Icon) -> some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(DesignTokens.Color.accent.opacity(0.13))
            .frame(width: 30, height: 30)
            .overlay {
                icon.image
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(DesignTokens.Color.accent)
            }
    }

    private func infoCard(_ row: SettingsInfoRow) -> some View {
        card {
            if let icon = row.icon {
                iconChip(icon)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(DesignTokens.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignTokens.Color.textPrimary)
                if let detail = row.detail {
                    Text(detail)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                }
            }
            if row.hasDisclosure {
                Spacer(minLength: DesignTokens.Spacing.s2)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesignTokens.Color.textSecondary)
            }
        }
    }

    private var versionCard: some View {
        card {
            Text("版本")
                .font(DesignTokens.Typography.body)
                .fontWeight(.semibold)
                .foregroundStyle(DesignTokens.Color.textPrimary)
            Spacer(minLength: DesignTokens.Spacing.s2)
            Text(model.appVersion)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Color.textSecondary)
        }
    }

    /// 「删除我的全部素材」：标题用**待改进色，不是纯红**（稿子原话，与全局色彩纪律一致）。
    /// 图标方块仍是强调色底（稿子 `.sr-ico` 只有一种底），要小心的是**字**。
    @ViewBuilder
    private func deleteCard(_ flow: SettingsDeleteFlow, icon: DesignTokens.Icon?) -> some View {
        Button {
            onDeleteTapped()
            isShowingDeleteConfirmation = true
        } label: {
            card {
                if let icon {
                    iconChip(icon)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("删除我的全部素材")
                        .font(DesignTokens.Typography.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignTokens.Color.improve)
                    Text(flow.isDeleting ? "正在删除…" : "二次确认后即时生效，并级联删除衍生的话术块")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                }
                if flow.isDeleting {
                    Spacer(minLength: DesignTokens.Spacing.s2)
                    ProgressView().progressViewStyle(.circular)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(flow.canDelete == false)
        .accessibilityIdentifier("settings.deleteAllMaterials")
    }

    #if DEBUG
        /// 开发者组（不在稿子里，只在 DEBUG 构建里存在）。
        ///
        /// 它沿用同一套卡，所以这一屏只有一种行形状 —— 混两种行样式会让「这是一屏」变成两屏。
        private var developerGroup: some View {
            group("开发者") {
                ForEach(model.flags) { row in
                    card {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                                .font(DesignTokens.Typography.body)
                                .fontWeight(.semibold)
                                .foregroundStyle(DesignTokens.Color.textPrimary)
                            if row.isOverridden {
                                Text("已被本地覆盖")
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundStyle(DesignTokens.Color.textSecondary)
                            }
                        }
                        Spacer(minLength: DesignTokens.Spacing.s2)
                        Toggle("", isOn: binding(for: row))
                            .labelsHidden()
                    }
                }

                // The escape hatch a device run needs. An override set on a
                // phone outlives the test that set it, and there is no other
                // way back to the build's defaults short of reinstalling.
                Button {
                    onClearOverrides()
                } label: {
                    card {
                        Text("清除全部本地覆盖")
                            .font(DesignTokens.Typography.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(
                                model.hasOverrides
                                    ? DesignTokens.Color.improve
                                    : DesignTokens.Color.textSecondary
                            )
                    }
                }
                .buttonStyle(.plain)
                .disabled(!model.hasOverrides)
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
