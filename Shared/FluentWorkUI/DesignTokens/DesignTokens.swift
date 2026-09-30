import CoreGraphics
import Foundation
import SwiftUI

/// Design tokens for FluentWork UI. Dark-default semantic colors; no page-level hardcoding.
public enum DesignTokens {
    /// Raw values exactly as the 2026-09-26 draft spells them (`--fw-*` in its CSS).
    public enum Hex {
        public static let background = "#1A2226"
        public static let backgroundElevated = "#232E33"
        public static let brand = "#4A7C82"
        public static let brandStrong = "#35646A"
        public static let accent = "#7FB3B8"
        public static let textPrimary = "#E8EDEF"
        public static let textSecondary = "#9AABAF"
        public static let success = "#6A9E7E"
        public static let training = "#C9A45C"
        public static let improve = "#C97B5C"
        public static let separatorBase = "#E8EDEF"
    }

    public enum Alpha {
        public static let separator: Double = 0.10
        public static let separatorStrong: Double = 0.20
        public static let wash: Double = 0.12
    }

    public enum Color {
        public static let background = SwiftUI.Color(hex: Hex.background)
        public static let backgroundElevated = SwiftUI.Color(hex: Hex.backgroundElevated)
        public static let brand = SwiftUI.Color(hex: Hex.brand)
        public static let brandStrong = SwiftUI.Color(hex: Hex.brandStrong)
        public static let accent = SwiftUI.Color(hex: Hex.accent)
        public static let textPrimary = SwiftUI.Color(hex: Hex.textPrimary)
        public static let textSecondary = SwiftUI.Color(hex: Hex.textSecondary)
        public static let success = SwiftUI.Color(hex: Hex.success)
        public static let training = SwiftUI.Color(hex: Hex.training)
        public static let improve = SwiftUI.Color(hex: Hex.improve)
        public static let separator = SwiftUI.Color(hex: Hex.separatorBase).opacity(Alpha.separator)
        public static let separatorStrong = SwiftUI.Color(hex: Hex.separatorBase).opacity(Alpha.separatorStrong)
        public static let wash = SwiftUI.Color(hex: Hex.accent).opacity(Alpha.wash)

        /// 把上面那张表里的字面量取回去。
        ///
        /// 存在的理由只有一个：状态灯（F2）的颜色要**能被判据核对**。`Color` 本身没法在判据里
        /// 可靠地比（构造路径不同就可能不等），所以 `CorpusStateLamp` 暴露的是 hex、视图走这一个
        /// 入口转回颜色 —— 于是「灯用哪个颜色」仍然只有一张表，而不是在灯里再抄一遍十六进制。
        public static func color(forHex hex: String) -> SwiftUI.Color {
            // 必须写全 `SwiftUI.Color` —— 在 `DesignTokens.Color` 里面，裸 `Color` 指的是它自己。
            SwiftUI.Color(hex: hex)
        }
    }

    public enum Typography {
        /// Display / room title
        public static let titlePointSize: CGFloat = 20
        public static let titleWeight: Font.Weight = .bold
        public static let cardTitlePointSize: CGFloat = 16
        public static let cardTitleWeight: Font.Weight = .bold
        /// Body
        public static let bodyPointSize: CGFloat = 15
        public static let bodyWeight: Font.Weight = .regular
        public static let bodyLineHeightMultiple: CGFloat = 1.5
        /// Secondary / caption
        public static let captionPointSize: CGFloat = 13
        public static let captionWeight: Font.Weight = .regular
        public static let monoPointSize: CGFloat = 15
        public static let englishPhraseWeight: Font.Weight = .medium

        public static var title: Font { .system(size: titlePointSize, weight: titleWeight) }
        public static var cardTitle: Font { .system(size: cardTitlePointSize, weight: cardTitleWeight) }
        public static var body: Font { .system(size: bodyPointSize, weight: bodyWeight) }
        public static var caption: Font { .system(size: captionPointSize, weight: captionWeight) }
        public static var englishPhrase: Font { .system(size: bodyPointSize, weight: englishPhraseWeight) }
        public static var mono: Font { .system(size: monoPointSize, design: .monospaced) }
    }

    public enum Spacing {
        public static let s1: CGFloat = 4
        public static let s2: CGFloat = 8
        public static let s3: CGFloat = 12
        public static let s4: CGFloat = 16
        public static let s6: CGFloat = 24
        public static let s8: CGFloat = 32
        public static let pageMargin: CGFloat = 16
    }

    public enum Radius {
        public static let card: CGFloat = 12
        public static let bubble: CGFloat = 16
        public static let capsule: CGFloat = 24
    }

    public enum Motion {
        /// Quick feedback (tap / toggle)
        public static let microSeconds: Double = 0.18
        /// Standard transition
        public static let transitionSeconds: Double = 0.28
        public static let exitDurationRatio: Double = 0.65
        public static let controlPoints = (x1: 0.22, y1: 0.61, x2: 0.36, y2: 1.0)

        public static var micro: Animation {
            .timingCurve(
                controlPoints.x1,
                controlPoints.y1,
                controlPoints.x2,
                controlPoints.y2,
                duration: microSeconds
            )
        }

        public static var transition: Animation {
            .timingCurve(
                controlPoints.x1,
                controlPoints.y1,
                controlPoints.x2,
                controlPoints.y2,
                duration: transitionSeconds
            )
        }

        public static var microExit: Animation { .easeIn(duration: microSeconds * exitDurationRatio) }
        public static var transitionExit: Animation { .easeIn(duration: transitionSeconds * exitDurationRatio) }
    }

    public enum Component {
        public static let talkButtonDiameter: CGFloat = 72
        public static let breathPeriodSeconds: Double = 3
        public static let breathScaleAmplitude: CGFloat = 0.03
        public static let statusDotDiameter: CGFloat = 8
        public static let badgePopSeconds: Double = 0.2
        public static let badgeDwellSeconds: Double = 1.5
        public static let minHitTarget: CGFloat = 44
        public static let minTargetSpacing: CGFloat = 8
        public static let focusRingWidth: CGFloat = 2
        public static let iconStrokeWidth: CGFloat = 1.5
        /// 图标名义边长。每张图的 SVG 是 24×24 的 `viewBox`（见稿子），
        /// 且 `preserves-vector-representation` 打开，所以它不是位图尺寸、可以任意放大。
        public static let iconPointSize: CGFloat = 24
    }

    /// 稿子里的 26 个 app 图标（值就是 asset catalog 名）。
    ///
    /// 资产由 `Scripts/generate-icons.py` 从稿子快照生成，**不要手抄也不要手改** ——
    /// 逐字保真由 `IconAssetTests` 盯着（改一个坐标点会被抓）。
    ///
    /// **命名规则是机械的**，这样「调用点的 case」到「稿子里的 symbol」可以反推：
    ///
    /// 1. 去掉稿子的 `i-` 前缀；
    /// 2. `chev-l` / `chev-r` / `chev-d` 展开成 `chevronLeft` / `chevronRight` /
    ///    `chevronDown` —— 单个字母当方向名在调用点读不出来；
    /// 3. 其余原样。`star4` 是**四角星**这个名字本身，不是「第 4 个 star」。
    ///
    /// 视图写 `DesignTokens.Icon.home`，不要写 `"i-home"` 字面量：asset 名写错
    /// 在编译期与 asset catalog 里都不报错，只在运行期画不出东西。
    public enum Icon: String, CaseIterable, Sendable {
        case book = "i-book"
        case check = "i-check"
        case chevronDown = "i-chev-d"
        case chevronLeft = "i-chev-l"
        case chevronRight = "i-chev-r"
        case clock = "i-clock"
        case copy = "i-copy"
        case doc = "i-doc"
        case drill = "i-drill"
        case flag = "i-flag"
        case gear = "i-gear"
        case home = "i-home"
        case info = "i-info"
        case ladder = "i-ladder"
        case library = "i-library"
        case mic = "i-mic"
        case pause = "i-pause"
        case play = "i-play"
        case replay = "i-replay"
        case search = "i-search"
        case shield = "i-shield"
        case star4 = "i-star4"
        case talk = "i-talk"
        case trash = "i-trash"
        case wave = "i-wave"
        case x = "i-x"
    }
}

public extension DesignTokens.Icon {
    /// 图标本体。
    ///
    /// 资源带 `template-rendering-intent: template`，所以它跟随 `foregroundStyle`；
    /// 稿子里写的是 `stroke="currentColor"`，语义与之一致（生成时归一化成 `#000`
    /// 只是为了给蒙版一个不透明描边，颜色由调用方决定）。
    var image: Image {
        Image(rawValue, bundle: .module)
    }
}

private extension Color {
    init(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var value: UInt64 = 0
        Scanner(string: digits).scanHexInt64(&value)
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}
