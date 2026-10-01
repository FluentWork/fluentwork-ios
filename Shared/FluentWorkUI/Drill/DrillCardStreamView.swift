import FluentWorkCore
import SwiftUI

/// 屏 05 · 闪测答题（Tab 2 的主屏）。
///
/// 稿子在这一屏的 note 里写了三条**看起来是细节、其实是产品**的纪律，都落在这里：
///
/// - **倒计时的语义**：5 秒不是从卡片出现开始算 —— 准备期 1 秒读题不计时，
///   作答 5 秒**从开始录音起算**（与后端 `response_ms` 口径对齐）。所以环只在 `isAnswering` 时才转。
/// - **焦虑控制**：细环**不闪烁**、不放数字跳动的大字；卡片下方给一个**不抢眼**的
///   「这题卡住了」；整页**无分数、无排名**。
/// - **判定等待**：话音落下 → 卡片 300ms 翻转进「判定中」（细环 ＋「正在听你说的…」，
///   不用百分比）→ 判定返回后展示对照（那是 屏 06）。
public struct DrillCardStreamView: View {
    private let model: DrillViewModel
    private let onAppear: () -> Void
    private let onExit: () -> Void
    /// 「这题卡住了」：跳过＝记失败并插入本轮尾部，**但由用户主动选择** ——
    /// 稿子原话：比盯着倒计时走完更能降低焦虑。
    private let onSkip: () -> Void
    private let onStartPractice: () -> Void

    public init(
        model: DrillViewModel,
        onAppear: @escaping () -> Void = {},
        onExit: @escaping () -> Void = {},
        onSkip: @escaping () -> Void = {},
        onStartPractice: @escaping () -> Void = {}
    ) {
        self.model = model
        self.onAppear = onAppear
        self.onExit = onExit
        self.onSkip = onSkip
        self.onStartPractice = onStartPractice
    }

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            switch model.screen {
            case .loading:
                loadingState
            case .empty:
                emptyState
            case .cardStream:
                cardStream
            case .verdict, .settlement:
                // 屏 06 / 屏 07 是各自的一屏（下一票）；在那一屏落地前不假装能显示。
                Color.clear
            case let .failed(message):
                failedState(message)
            }
            Spacer(minLength: 0)
        }
        .background(DesignTokens.Color.background)
        .onAppear(perform: onAppear)
    }

    private var topBar: some View {
        HStack(spacing: DesignTokens.Spacing.s3) {
            Text("闪测")
                .font(DesignTokens.Typography.cardTitle)
                .foregroundStyle(DesignTokens.Color.textPrimary)
            Spacer()
            // 「第 3 / 10 题」—— 进度是**位置**，不是分数。
            if let card = model.card {
                Text("第 \(card.position) / \(card.planned) 题")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
                    .accessibilityIdentifier("drill.progress")
            }
            Button(action: onExit) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignTokens.Color.textSecondary)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("退出闪测")
            .accessibilityIdentifier("drill.exit")
        }
        .padding(.horizontal, DesignTokens.Spacing.pageMargin)
        .padding(.vertical, DesignTokens.Spacing.s2)
    }

    private var cardStream: some View {
        VStack(spacing: DesignTokens.Spacing.s6) {
            stage
            if model.card?.isAnswering == true {
                countdownRing
            }
            micButton
            // 「这题卡住了」**不抢眼**（quiet）—— 它是出口，不是主按钮。
            Button(action: onSkip) {
                Text("这题卡住了")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
                    .padding(.horizontal, DesignTokens.Spacing.s4)
                    .padding(.vertical, DesignTokens.Spacing.s3)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("drill.skip")
        }
        .padding(.horizontal, DesignTokens.Spacing.pageMargin)
        .padding(.top, DesignTokens.Spacing.s6)
    }

    private var stage: some View {
        VStack(spacing: DesignTokens.Spacing.s3) {
            // 提示条件写在意图**上面**：先说清这一题怎么算（无提示 / 限时），
            // 再给要说的内容 —— 反过来读的人会先看到题干再找规则。
            Text("无提示 · 限时 \(Int(model.card?.answerSeconds ?? 5)) 秒 · 口头作答")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Color.textSecondary)
            Text(model.card?.intentZH ?? "")
                .font(DesignTokens.Typography.title)
                .foregroundStyle(DesignTokens.Color.textPrimary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, DesignTokens.Spacing.s4)
                .accessibilityIdentifier("drill.intent")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignTokens.Spacing.s8)
        .background(DesignTokens.Color.backgroundElevated)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.bubble, style: .continuous))
    }

    /// 倒计时：**细环 ＋ 静态数字**（稿子：不闪烁、不放跳动的大字）。
    private var countdownRing: some View {
        VStack(spacing: DesignTokens.Spacing.s1) {
            ZStack {
                Circle()
                    .stroke(DesignTokens.Color.separator, lineWidth: 2)
                    .frame(width: 56, height: 56)
                Text("\(Int(model.card?.answerSeconds ?? 5))")
                    .font(DesignTokens.Typography.cardTitle)
                    .foregroundStyle(DesignTokens.Color.textPrimary)
                    .monospacedDigit()
            }
            Text("作答倒计时")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Color.textSecondary)
        }
        .accessibilityIdentifier("drill.countdown")
    }

    private var micButton: some View {
        ZStack {
            Circle()
                .fill(DesignTokens.Color.brandStrong)
                .frame(width: 84, height: 84)
            DesignTokens.Icon.mic.image
                .font(.system(size: 30))
                .foregroundStyle(DesignTokens.Color.textPrimary)
        }
        .accessibilityLabel("开始作答")
        .accessibilityIdentifier("drill.mic")
    }

    private var loadingState: some View {
        VStack(spacing: DesignTokens.Spacing.s3) {
            ProgressView().progressViewStyle(.circular)
            Text("正在挑这一轮要问你的表达…")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Color.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, DesignTokens.Spacing.s8)
    }

    /// 空态：**说清为什么没有，并给一条出路**（没有话术块的闪测没有可考核的对象）。
    private var emptyState: some View {
        VStack(spacing: DesignTokens.Spacing.s3) {
            Text(model.emptyTitle)
                .font(DesignTokens.Typography.cardTitle)
                .foregroundStyle(DesignTokens.Color.textPrimary)
            Text(model.emptyDetail)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Color.textSecondary)
                .multilineTextAlignment(.center)
            Button(action: onStartPractice) {
                Text(model.emptyCTATitle)
                    .font(DesignTokens.Typography.cardTitle)
                    .foregroundStyle(DesignTokens.Color.textPrimary)
                    .padding(.horizontal, DesignTokens.Spacing.s6)
                    .padding(.vertical, DesignTokens.Spacing.s3)
                    .background(DesignTokens.Color.brandStrong)
                    .clipShape(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, DesignTokens.Spacing.s2)
            .accessibilityIdentifier("drill.emptyCTA")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DesignTokens.Spacing.pageMargin)
        .padding(.top, DesignTokens.Spacing.s8)
    }

    private func failedState(_ message: String) -> some View {
        VStack(spacing: DesignTokens.Spacing.s3) {
            Text("这一轮没能开始")
                .font(DesignTokens.Typography.cardTitle)
                .foregroundStyle(DesignTokens.Color.textPrimary)
            Text(message)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Color.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DesignTokens.Spacing.pageMargin)
        .padding(.top, DesignTokens.Spacing.s8)
    }
}
