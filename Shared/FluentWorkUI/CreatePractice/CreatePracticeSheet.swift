import FluentWorkCore
import SwiftUI

/// 创建练习弹层（09-26 稿 屏 11）。
///
/// **它是弹层不是全屏页**：稿子 §03 把创建练习归在「底部弹层，非全屏」，关键路径审计
/// 记的是「工作台 →『开始新练习』→ 创建弹层选场景 → 说的房间 = 2 次点击」——
/// 学员在这一屏上做的是**选**，不是读，占满整屏只会把上一屏的上下文抹掉。
///
/// 颜色、字号、间距、圆角一律走 `DesignTokens`：这一屏不该有自己的一套数值。
public struct CreatePracticeSheet: View {
    private let model: CreatePracticeViewModel
    private let onInputChanged: (CreatePracticeInput) -> Void
    private let onDraftChanged: (String) -> Void
    private let onLengthChanged: (PracticeSessionLength) -> Void
    private let onSubmit: () -> Void
    private let onClose: () -> Void

    public init(
        model: CreatePracticeViewModel,
        onInputChanged: @escaping (CreatePracticeInput) -> Void,
        onDraftChanged: @escaping (String) -> Void,
        onLengthChanged: @escaping (PracticeSessionLength) -> Void,
        onSubmit: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.model = model
        self.onInputChanged = onInputChanged
        self.onDraftChanged = onDraftChanged
        self.onLengthChanged = onLengthChanged
        self.onSubmit = onSubmit
        self.onClose = onClose
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.s6) {
                header
                inputPicker
                materialSection
                lengthSection
                submitSection
            }
            .padding(.horizontal, DesignTokens.Spacing.pageMargin)
            .padding(.top, DesignTokens.Spacing.s4)
            .padding(.bottom, DesignTokens.Spacing.s6)
        }
        .background(DesignTokens.Color.background)
        .presentationDetents([.fraction(0.78), .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(model.title)
                .font(DesignTokens.Typography.title)
                .foregroundStyle(DesignTokens.Color.textPrimary)

            Spacer(minLength: DesignTokens.Spacing.s3)

            // 稿子 §03 的导航纪律：模态与抽屉都要有**明确的**关闭方式。
            // 下滑手势算一半 —— 它是隐式的，读屏用户与手抖的人都不该只能靠它。
            Button(action: onClose) {
                DesignTokens.Icon.x.image
                    .font(.system(size: DesignTokens.Component.iconPointSize * 0.8, weight: .medium))
                    .foregroundStyle(DesignTokens.Color.textSecondary)
                    .frame(
                        width: DesignTokens.Component.minHitTarget,
                        height: DesignTokens.Component.minHitTarget,
                        alignment: .trailing
                    )
            }
            .accessibilityLabel("关闭")
            .accessibilityIdentifier("create-practice.close")
        }
    }

    // MARK: - 三种输入方式

    private var inputPicker: some View {
        HStack(spacing: DesignTokens.Spacing.s2) {
            ForEach(model.inputs) { option in
                Button {
                    guard let input = CreatePracticeInput(rawValue: option.id) else { return }
                    onInputChanged(input)
                } label: {
                    Text(option.title)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(
                            option.isSelected
                                ? DesignTokens.Color.textPrimary
                                : DesignTokens.Color.textSecondary
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DesignTokens.Spacing.s2)
                        .background(
                            option.isSelected
                                ? DesignTokens.Color.brand
                                : DesignTokens.Color.backgroundElevated,
                            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("create-practice.input.\(option.id)")
                .accessibilityAddTraits(option.isSelected ? [.isSelected] : [])
            }
        }
    }

    // MARK: - 素材

    @ViewBuilder
    private var materialSection: some View {
        if model.showsDraftField {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.s2) {
                Text(model.draftLabel)
                    .font(DesignTokens.Typography.cardTitle)
                    .foregroundStyle(DesignTokens.Color.textPrimary)

                ZStack(alignment: .topLeading) {
                    if model.draftCountIsEmpty {
                        Text(model.draftPlaceholder)
                            .font(DesignTokens.Typography.body)
                            .foregroundStyle(DesignTokens.Color.textSecondary)
                            .padding(.horizontal, DesignTokens.Spacing.s3)
                            .padding(.vertical, DesignTokens.Spacing.s3)
                            .allowsHitTesting(false)
                    }

                    TextEditor(
                        text: Binding(
                            get: { model.draft },
                            set: onDraftChanged
                        )
                    )
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Color.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 104)
                    .padding(.horizontal, DesignTokens.Spacing.s2)
                    .padding(.vertical, DesignTokens.Spacing.s2)
                    .accessibilityIdentifier("create-practice.draft")
                }
                .background(
                    DesignTokens.Color.backgroundElevated,
                    in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                )

                HStack(spacing: DesignTokens.Spacing.s2) {
                    if let over = model.overLimitMessage {
                        Text(over)
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.Color.improve)
                    } else if let short = model.shortfallMessage {
                        Text(short)
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.Color.textSecondary)
                    }

                    Spacer(minLength: DesignTokens.Spacing.s2)

                    // 字数照实报：超限不截断，所以这个数字是学员唯一的依据。
                    Text("\(model.characterCount) / \(model.characterLimit)")
                        .font(DesignTokens.Typography.caption)
                        .monospacedDigit()
                        .foregroundStyle(
                            model.overLimitMessage == nil
                                ? DesignTokens.Color.textSecondary
                                : DesignTokens.Color.improve
                        )
                }
            }
        } else {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.s2) {
                Text("用预置场景")
                    .font(DesignTokens.Typography.cardTitle)
                    .foregroundStyle(DesignTokens.Color.textPrimary)
                Text(model.presetSceneTitle)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Color.textPrimary)
                    .padding(.horizontal, DesignTokens.Spacing.s3)
                    .padding(.vertical, DesignTokens.Spacing.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        DesignTokens.Color.backgroundElevated,
                        in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                    )
            }
        }

        // 常驻的隐私声明。它跟着素材输入走 —— 说的就是这段素材。
        HStack(alignment: .top, spacing: DesignTokens.Spacing.s2) {
            DesignTokens.Icon.shield.image
                .font(.system(size: DesignTokens.Component.iconPointSize * 0.7))
                .foregroundStyle(DesignTokens.Color.accent)
            Text(model.privacyNotice)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Color.textSecondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("create-practice.privacy")
    }

    // MARK: - 会话时长

    private var lengthSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s2) {
            Text(model.lengthSectionTitle)
                .font(DesignTokens.Typography.cardTitle)
                .foregroundStyle(DesignTokens.Color.textPrimary)

            HStack(spacing: DesignTokens.Spacing.s3) {
                ForEach(model.lengthOptions) { option in
                    Button {
                        guard let length = PracticeSessionLength(rawValue: option.id) else { return }
                        onLengthChanged(length)
                    } label: {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s1) {
                            Text(option.title)
                                .font(DesignTokens.Typography.cardTitle)
                                .foregroundStyle(DesignTokens.Color.textPrimary)
                            // 迷你同样写清回合数与时长 —— 稿子要求两者并列呈现、不做视觉降级。
                            Text(option.detail)
                                .font(DesignTokens.Typography.caption)
                                .foregroundStyle(DesignTokens.Color.textSecondary)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DesignTokens.Spacing.s3)
                        .background(
                            option.isSelected ? DesignTokens.Color.wash : DesignTokens.Color.backgroundElevated,
                            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                                .stroke(
                                    option.isSelected
                                        ? DesignTokens.Color.brand
                                        : DesignTokens.Color.separator,
                                    lineWidth: option.isSelected ? DesignTokens.Component.focusRingWidth : 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("create-practice.length.\(option.id)")
                    .accessibilityAddTraits(option.isSelected ? [.isSelected] : [])
                }
            }
        }
    }

    // MARK: - 提交

    private var submitSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s3) {
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Color.improve)
                    .accessibilityIdentifier("create-practice.error")
            }

            Button(action: onSubmit) {
                HStack(spacing: DesignTokens.Spacing.s2) {
                    if model.isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(DesignTokens.Color.textPrimary)
                    }
                    Text(model.submitTitle)
                        .font(DesignTokens.Typography.cardTitle)
                        .foregroundStyle(
                            model.canSubmit
                                ? DesignTokens.Color.textPrimary
                                : DesignTokens.Color.textSecondary
                        )
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: DesignTokens.Component.minHitTarget)
                .background(
                    model.canSubmit
                        ? DesignTokens.Color.brandStrong
                        : DesignTokens.Color.backgroundElevated,
                    in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .disabled(!model.canSubmit)
            .accessibilityIdentifier("create-practice.submit")
        }
    }
}

extension CreatePracticeViewModel {
    /// 输入框空不空。放在这里而不是让视图直接读 `draft`：
    /// 「空」的定义（是不是只有空白字符）只该有一处。
    public var draftCountIsEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
