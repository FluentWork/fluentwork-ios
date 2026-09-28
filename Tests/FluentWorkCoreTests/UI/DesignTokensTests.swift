import Foundation
import SwiftUI
import Testing

@testable import FluentWorkUI

@Test func paletteMatchesThe0926Draft() {
    let palette: [(variable: String, actual: String, expected: String)] = [
        ("--fw-bg", DesignTokens.Hex.background, "#1A2226"),
        ("--fw-bg-elev", DesignTokens.Hex.backgroundElevated, "#232E33"),
        ("--fw-brand", DesignTokens.Hex.brand, "#4A7C82"),
        ("--fw-brand-strong", DesignTokens.Hex.brandStrong, "#35646A"),
        ("--fw-accent", DesignTokens.Hex.accent, "#7FB3B8"),
        ("--fw-text", DesignTokens.Hex.textPrimary, "#E8EDEF"),
        ("--fw-text-2", DesignTokens.Hex.textSecondary, "#9AABAF"),
        ("--fw-success", DesignTokens.Hex.success, "#6A9E7E"),
        ("--fw-training", DesignTokens.Hex.training, "#C9A45C"),
        ("--fw-improve", DesignTokens.Hex.improve, "#C97B5C"),
        ("--fw-line base", DesignTokens.Hex.separatorBase, "#E8EDEF"),
    ]

    for entry in palette {
        #expect(entry.actual == entry.expected, "\(entry.variable) is \(entry.actual), draft says \(entry.expected)")
    }
}

@Test func alphaScaleMatchesThe0926Draft() {
    #expect(DesignTokens.Alpha.separator == 0.10)
    #expect(DesignTokens.Alpha.separatorStrong == 0.20)
    #expect(DesignTokens.Alpha.wash == 0.12)
}

@Test func typographyMatchesThe0926Draft() {
    let scale: [(variable: String, actual: CGFloat, expected: CGFloat)] = [
        ("title 20pt", DesignTokens.Typography.titlePointSize, 20),
        ("card title 16pt", DesignTokens.Typography.cardTitlePointSize, 16),
        ("body 15pt", DesignTokens.Typography.bodyPointSize, 15),
        ("caption 13pt", DesignTokens.Typography.captionPointSize, 13),
        ("mono 15pt", DesignTokens.Typography.monoPointSize, 15),
        ("body line height", DesignTokens.Typography.bodyLineHeightMultiple, 1.5),
    ]

    for entry in scale {
        #expect(entry.actual == entry.expected, "\(entry.variable) is \(entry.actual), draft says \(entry.expected)")
    }

    #expect(DesignTokens.Typography.titleWeight == .bold)
    #expect(DesignTokens.Typography.cardTitleWeight == .bold)
    #expect(DesignTokens.Typography.bodyWeight == .regular)
    #expect(DesignTokens.Typography.captionWeight == .regular)
    #expect(DesignTokens.Typography.englishPhraseWeight == .medium)
}

@Test func spacingFollowsTheFourPointScale() {
    let steps: [(variable: String, actual: CGFloat, expected: CGFloat)] = [
        ("4pt", DesignTokens.Spacing.s1, 4),
        ("8pt", DesignTokens.Spacing.s2, 8),
        ("12pt", DesignTokens.Spacing.s3, 12),
        ("16pt", DesignTokens.Spacing.s4, 16),
        ("24pt", DesignTokens.Spacing.s6, 24),
        ("32pt", DesignTokens.Spacing.s8, 32),
        ("page margin", DesignTokens.Spacing.pageMargin, 16),
    ]

    for entry in steps {
        #expect(entry.actual == entry.expected, "\(entry.variable) is \(entry.actual), draft says \(entry.expected)")
        #expect(entry.actual.truncatingRemainder(dividingBy: 4) == 0, "\(entry.variable) is off the 4pt grid")
    }
}

@Test func radiiMatchTheThreeStepScale() {
    #expect(DesignTokens.Radius.card == 12)
    #expect(DesignTokens.Radius.bubble == 16)
    #expect(DesignTokens.Radius.capsule == 24)
}

@Test func motionMatchesThe0926Draft() {
    #expect(DesignTokens.Motion.microSeconds == 0.18)
    #expect(DesignTokens.Motion.transitionSeconds == 0.28)
    #expect(DesignTokens.Motion.exitDurationRatio == 0.65)
    #expect(DesignTokens.Motion.controlPoints.x1 == 0.22)
    #expect(DesignTokens.Motion.controlPoints.y1 == 0.61)
    #expect(DesignTokens.Motion.controlPoints.x2 == 0.36)
    #expect(DesignTokens.Motion.controlPoints.y2 == 1.0)

    #expect(DesignTokens.Motion.microSeconds >= 0.15 && DesignTokens.Motion.microSeconds <= 0.20)
    #expect(DesignTokens.Motion.transitionSeconds >= 0.25 && DesignTokens.Motion.transitionSeconds <= 0.30)
    #expect(DesignTokens.Motion.exitDurationRatio >= 0.60 && DesignTokens.Motion.exitDurationRatio <= 0.70)
}

@Test func componentSpecsMatchThe0926Draft() {
    let specs: [(variable: String, actual: Double, expected: Double)] = [
        ("talk button", Double(DesignTokens.Component.talkButtonDiameter), 72),
        ("breath period", DesignTokens.Component.breathPeriodSeconds, 3),
        ("breath amplitude", Double(DesignTokens.Component.breathScaleAmplitude), 0.03),
        ("status dot", Double(DesignTokens.Component.statusDotDiameter), 8),
        ("badge pop", DesignTokens.Component.badgePopSeconds, 0.2),
        ("badge dwell", DesignTokens.Component.badgeDwellSeconds, 1.5),
        ("min hit target", Double(DesignTokens.Component.minHitTarget), 44),
        ("min target spacing", Double(DesignTokens.Component.minTargetSpacing), 8),
        ("focus ring", Double(DesignTokens.Component.focusRingWidth), 2),
        ("icon stroke", Double(DesignTokens.Component.iconStrokeWidth), 1.5),
    ]

    for entry in specs {
        #expect(entry.actual == entry.expected, "\(entry.variable) is \(entry.actual), draft says \(entry.expected)")
    }
}

@Test func darkPaletteMeetsTheDocumentedContrastFloor() {
    let background = DesignTokens.Hex.background
    let bodyText = DesignTokens.Hex.textPrimary

    let mustPassAA = [
        ("--fw-text (body)", bodyText),
        ("--fw-text-2", DesignTokens.Hex.textSecondary),
        ("--fw-accent", DesignTokens.Hex.accent),
        ("--fw-success", DesignTokens.Hex.success),
        ("--fw-training", DesignTokens.Hex.training),
        ("--fw-improve", DesignTokens.Hex.improve),
    ]

    for entry in mustPassAA {
        let ratio = contrastRatio(entry.1, background)
        #expect(ratio >= 4.5, "\(entry.0) is \(rounded(ratio)):1 on the page background, below the AA floor of 4.5:1")
    }

    let bodyRatio = contrastRatio(bodyText, background)
    #expect(bodyRatio >= 7.0, "body text is \(rounded(bodyRatio)):1, below the AAA floor of 7:1")

    let brandRatio = contrastRatio(DesignTokens.Hex.brand, background)
    #expect(
        brandRatio < 4.5,
        "--fw-brand reached \(rounded(brandRatio)):1 — it is documented as decoration only; passing AA means the draft was re-specified"
    )

    let buttonRatio = contrastRatio(DesignTokens.Hex.brandStrong, bodyText)
    #expect(buttonRatio >= 4.5, "the solid button is \(rounded(buttonRatio)):1 against its label, below the AA floor")
}

@Test func hexColorLiteralsLiveOnlyInDesignTokens() throws {
    let root = repositoryRoot
    let allowed = "Shared/FluentWorkUI/DesignTokens/DesignTokens.swift"
    let pattern = try NSRegularExpression(pattern: "#[0-9A-Fa-f]{6}\\b")

    var scanned = 0
    var offenders: [String] = []

    for top in ["Shared", "App"] {
        let base = root.appending(path: top)
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
            continue
        }
        for case let url as URL in walker where url.pathExtension == "swift" {
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            if relative == allowed { continue }
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if pattern.firstMatch(in: text, range: range) != nil {
                offenders.append(relative)
            }
        }
    }

    #expect(scanned > 100, "the walk only reached \(scanned) Swift files — the guard is looking at nothing")
    #expect(offenders.isEmpty, "hardcoded hex colors outside DesignTokens: \(offenders.joined(separator: ", "))")
}

private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func rounded(_ value: Double) -> String {
    String(format: "%.2f", value)
}

private func contrastRatio(_ lhs: String, _ rhs: String) -> Double {
    let a = relativeLuminance(lhs)
    let b = relativeLuminance(rhs)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

private func relativeLuminance(_ hex: String) -> Double {
    let channels = rgb(hex).map { channel -> Double in
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
}

private func rgb(_ hex: String) -> [Double] {
    let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    var value: UInt64 = 0
    Scanner(string: digits).scanHexInt64(&value)
    return [
        Double((value >> 16) & 0xFF) / 255,
        Double((value >> 8) & 0xFF) / 255,
        Double(value & 0xFF) / 255,
    ]
}
