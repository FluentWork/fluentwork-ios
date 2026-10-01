import SwiftUI

/// 闪光骨架块 —— 加载态的统一形状（稿子 §2.4「骨架屏 · 加载态」）。
///
/// 稿子对它有一条明确的态度：**不用转圈 spinner**，因为「工程师用户对『系统活着但没内容』的
/// 感知更准确」—— 骨架块的形状就是内容将要出现的形状，转圈只说明有东西在转。同一句里点名了
/// 四个页面（语料库 / 历史 / 每日一读 / 回顾），所以它住在这里而不是某一个屏的目录下。
///
/// 动效受 `accessibilityReduceMotion` 管：稿子 §4 写着「`prefers-reduced-motion` 下呼吸、波纹、
/// **骨架闪光**全部停止」。这里停止的是**闪烁**，骨架块本身仍然在 —— 那才是它的信息。
public struct SkeletonBlock: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let height: CGFloat
    /// 占容器宽度的比例。默认整宽；短一点的块让骨架看起来像几行字，而不是一整块灰。
    private let widthRatio: CGFloat

    @State private var isDimmed = false

    public init(height: CGFloat, widthRatio: CGFloat = 1) {
        self.height = height
        self.widthRatio = max(0, min(1, widthRatio))
    }

    public var body: some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                .fill(DesignTokens.Color.backgroundElevated)
                .frame(width: proxy.size.width * widthRatio)
                .opacity(opacity)
        }
        .frame(height: height)
        // 闪光 = 透明度来回走。`repeatForever(autoreverses:)` 只在减少动效关闭时挂上：
        // 真机上开着「减弱动态效果」的人看到的应该是一块**静止**的骨架，而不是更慢的闪。
        .animation(
            reduceMotion
                ? nil
                : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
            value: isDimmed
        )
        // 骨架是**装饰**：它不含信息，VoiceOver 该听到的是旁边那句文案。
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            isDimmed = true
        }
    }

    private var opacity: Double {
        guard !reduceMotion else { return 0.75 }
        return isDimmed ? 0.45 : 0.9
    }
}

/// 「一列东西正在加载」的骨架：一句说明（可选）+ N 个行块。
///
/// 三个列表页（语料库 / 练习历史 / 会话详情）的加载态形状是同一件事，所以它跟着
/// `SkeletonBlock` 一起住在这里 —— 每个页面各写一遍「四组圆角块」，迟早就各长一个样，
/// 而稿子 §2.4 要的正是**统一**。
///
/// `label` 用各页原来那句话（「加载语料库…」之类），一个字都不改：换骨架只是换**形状**，
/// 不该顺手改文案。
public struct ListSkeletonPlaceholder: View {
    private let label: String?
    private let rowCount: Int

    public init(label: String? = nil, rowCount: Int = 4) {
        self.label = label
        self.rowCount = max(1, rowCount)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s3) {
            if let label, !label.isEmpty {
                Text(label)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
            }

            ForEach(0..<rowCount, id: \.self) { _ in
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.s2) {
                    SkeletonBlock(height: 16, widthRatio: 0.55)
                    SkeletonBlock(height: 12, widthRatio: 0.9)
                }
            }
        }
        .padding(.vertical, DesignTokens.Spacing.s1)
    }
}
