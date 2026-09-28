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
