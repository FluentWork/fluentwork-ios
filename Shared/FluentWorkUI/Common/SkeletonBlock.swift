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
