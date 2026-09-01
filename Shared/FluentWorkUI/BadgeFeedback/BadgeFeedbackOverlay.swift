import SwiftUI

// MARK: - View model

public struct BadgeFeedbackRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var badge: String
    public var tier: BadgeTier

    public init(id: String, badge: String, tier: BadgeTier) {
        self.id = id
        self.badge = badge
        self.tier = tier
    }

    public enum BadgeTier: String, Equatable, Sendable {
        case sameTurnConfirm
        case nextTurnConfirm
        case badgeOnly
        case unknown
    }
}

public struct BadgeFeedbackViewModel: Equatable, Sendable {
    public var badges: [BadgeFeedbackRow]
    public var maxVisible: Int

    public init(
        badges: [BadgeFeedbackRow] = [],
        maxVisible: Int = 3
    ) {
        self.badges = badges
        self.maxVisible = maxVisible
    }

    public var visibleBadges: [BadgeFeedbackRow] {
        Array(badges.prefix(maxVisible))
    }

    public var isEmpty: Bool { visibleBadges.isEmpty }
}

// MARK: - Overlay

/// Lightweight, non-blocking badge overlay (`I11`).
///
/// Visual constraints (`05_第二波开发范围与任务清单.md` §7):
///  * Non-modal, no pop-up, no vibration, no system alert.
///  * Never blocks the voice stream.
///  * Anti-spam: respects `maxVisible`; dedupe/dispatch-time windowing
///    happens upstream in `BadgeFeedbackReducer`.
public struct BadgeFeedbackOverlay: View {
    private let model: BadgeFeedbackViewModel

    public init(model: BadgeFeedbackViewModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 6) {
            ForEach(model.visibleBadges) { row in
                BadgeFeedbackRowView(row: row)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity
                        )
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .animation(.easeInOut(duration: 0.25), value: model.badges.map(\.id))
    }
}

// MARK: - Row

private struct BadgeFeedbackRowView: View {
    let row: BadgeFeedbackRow

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.caption.weight(.semibold))
            Text(row.badge)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(backgroundStyle)
        .foregroundStyle(foregroundStyle)
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("命中反馈 \(row.badge)"))
    }

    private var iconName: String {
        switch row.tier {
        case .sameTurnConfirm: "checkmark.seal.fill"
        case .nextTurnConfirm: "checkmark.circle.fill"
        case .badgeOnly: "sparkles"
        case .unknown: "sparkles"
        }
    }

    private var backgroundStyle: AnyShapeStyle {
        switch row.tier {
        case .sameTurnConfirm:
            return AnyShapeStyle(Color.green.opacity(0.18))
        case .nextTurnConfirm:
            return AnyShapeStyle(Color.blue.opacity(0.16))
        case .badgeOnly, .unknown:
            return AnyShapeStyle(Color.secondary.opacity(0.18))
        }
    }

    private var foregroundStyle: some ShapeStyle {
        switch row.tier {
        case .sameTurnConfirm: Color.green
        case .nextTurnConfirm: Color.blue
        case .badgeOnly, .unknown: Color.primary
        }
    }
}

#if DEBUG
  extension BadgeFeedbackViewModel {
    public static let previewEmpty = BadgeFeedbackViewModel()

    public static let previewSingle = BadgeFeedbackViewModel(
      badges: [
        BadgeFeedbackRow(id: "p-1", badge: "表达自然", tier: .unknown),
      ],
      maxVisible: 3
    )

    public static let previewStacked = BadgeFeedbackViewModel(
      badges: [
        BadgeFeedbackRow(id: "p-1", badge: "表达自然", tier: .nextTurnConfirm),
        BadgeFeedbackRow(id: "p-2", badge: "节奏稳定", tier: .badgeOnly),
        BadgeFeedbackRow(id: "p-3", badge: "用词地道", tier: .unknown),
        BadgeFeedbackRow(id: "p-4", badge: "太多填充词", tier: .badgeOnly),
      ],
      maxVisible: 3
    )
  }
#endif
