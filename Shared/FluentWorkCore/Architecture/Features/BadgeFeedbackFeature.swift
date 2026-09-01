import FluentWorkDiagnostics
import FluentWorkNetworking
import Foundation
import TGReduxKit

// MARK: - Domain types

/// One badge hit surfaced to the iOS UI.
///
/// `tier` mirrors `internal/voicepoc/window.go` Tier semantics so the UI can
/// decide visual weight once backend `B12` reports the resolved tier via the
/// `feedback.badge` control frame. While `B12` is still booting in main-line
/// we fall back to `.unknown` (iOS still shows the badge).
public struct BadgeFeedEntry: Equatable, Sendable, Identifiable, Hashable {
    public enum Tier: String, Equatable, Sendable, Hashable {
        /// Same-turn confirm (tier ①). Reserved for when backend can confirm
        /// the hit inside the current turn — kept for future tier-aware
        /// visuals.
        case sameTurnConfirm
        /// Next-turn open confirm (tier ②).
        case nextTurnConfirm
        /// Badge only (tier ③). Default until backend reports a tier.
        case badgeOnly
        /// Resolved tier not yet known (pre-B12 main-line).
        case unknown

        /// Maps the wire-format `FeedbackBadgeTier` (B12 display weight) into
        /// the iOS display tier. The two value sets describe different axes
        /// (B12 = visual weight, B7 = confirmation level), so the mapping is
        /// intentionally lossy and documented here as the single source of
        /// truth.
        ///
        /// - `soft`      → `.badgeOnly`        (lightest visual, no extra confirm)
        /// - `highlight` → `.nextTurnConfirm`  (mid visual, matches "next-turn"
        ///                                     confirm in the original B7 model)
        /// - `celebrate` → `.sameTurnConfirm`  (highest visual, matches
        ///                                     "same-turn" confirm in B7)
        public static func from(transport tier: FeedbackBadgeTier) -> Tier {
            switch tier {
            case .soft: return .badgeOnly
            case .highlight: return .nextTurnConfirm
            case .celebrate: return .sameTurnConfirm
            }
        }
    }

    public let id: UUID
    public let badge: String
    public let phraseBlockID: String?
    public let turnID: String?
    public let tier: Tier
    public let receivedAt: Date

    public init(
        id: UUID = UUID(),
        badge: String,
        phraseBlockID: String? = nil,
        turnID: String? = nil,
        tier: Tier = .unknown,
        receivedAt: Date
    ) {
        self.id = id
        self.badge = badge
        self.phraseBlockID = phraseBlockID
        self.turnID = turnID
        self.tier = tier
        self.receivedAt = receivedAt
    }
}

// MARK: - State

/// Display-only state for `I11` badge feedback.
///
/// Lives outside `SpeechSessionState` on purpose: the speaking-room state
/// machine must never be disturbed by presentation concerns (`02_iOS架构
/// 实现约定.md` §2.2 — badge feedback is a display action).
public struct BadgeFeedbackState: Equatable, Sendable, State {
    /// Entries in arrival order (oldest first).
    public var entries: [BadgeFeedEntry]
    /// How long an entry stays visible (seconds).
    public var visibleWindowSeconds: Double
    /// How long a (badge, turnID) pair is considered "the same hit" and
    /// suppressed from re-adding (seconds).
    public var dedupeWindowSeconds: Double
    /// Cap on visible entries — defends against spam bursts.
    public var maxVisibleEntries: Int
    /// Last time the reducer ran, used by tests + middleware to coalesce
    /// ticks.
    public var lastTickAt: Date?

    public init(
        entries: [BadgeFeedEntry] = [],
        visibleWindowSeconds: Double = 4.0,
        dedupeWindowSeconds: Double = 5.0,
        maxVisibleEntries: Int = 3,
        lastTickAt: Date? = nil
    ) {
        self.entries = entries
        self.visibleWindowSeconds = visibleWindowSeconds
        self.dedupeWindowSeconds = dedupeWindowSeconds
        self.maxVisibleEntries = maxVisibleEntries
        self.lastTickAt = lastTickAt
    }

    /// Currently-visible entries, sorted by receivedAt ascending.
    public func visibleEntries(at now: Date) -> [BadgeFeedEntry] {
        let cutoff = now.addingTimeInterval(-visibleWindowSeconds)
        return entries
            .filter { $0.receivedAt >= cutoff }
            .sorted { $0.receivedAt < $1.receivedAt }
    }

    /// True when nothing should be rendered.
    public var isEmpty: Bool { entries.isEmpty }

    /// In-place ingest helper — exposed so cross-cutting reducers that don't
    /// have a `(inout, Action)` two-argument shape (e.g. inside
    /// `appCrossCuttingReducer`) can still apply the same semantics.
    ///
    /// `phraseBlockID` is the corpus-side identifier the backend attached to
    /// the `feedback.badge` frame. When present it extends the dedupe key
    /// so the same badge for the same phrase block cannot re-render inside
    /// the dedupe window even if the turnID was missed.
    public mutating func ingest(
        badge: String,
        turnID: String?,
        tier: BadgeFeedEntry.Tier,
        at: Date,
        phraseBlockID: String? = nil
    ) {
        guard !badge.isEmpty else { return }

        let dedupeCutoff = at.addingTimeInterval(-dedupeWindowSeconds)
        let isDuplicate = entries.contains { existing in
            guard existing.receivedAt >= dedupeCutoff else { return false }
            if existing.badge != badge { return false }
            if existing.turnID != turnID { return false }
            return existing.phraseBlockID == phraseBlockID
        }
        guard !isDuplicate else { return }

        entries.append(
            BadgeFeedEntry(
                badge: badge,
                phraseBlockID: phraseBlockID,
                turnID: turnID,
                tier: tier,
                receivedAt: at
            )
        )

        // Cap to most recent maxVisibleEntries to keep memory bounded even
        // when the timer hasn't fired yet.
        if entries.count > maxVisibleEntries {
            let overflow = entries.count - maxVisibleEntries
            entries.removeFirst(overflow)
        }
        lastTickAt = at
    }
}

// MARK: - Actions

public enum BadgeFeedbackAction: Equatable, Sendable, Action {
    /// Add a new badge hit (deduped against recent same turnID+badge).
    case ingest(badge: String, turnID: String?, tier: BadgeFeedEntry.Tier, at: Date)
    /// Periodic tick — sweeps expired entries.
    case tick(at: Date)
    /// Wipe all entries (e.g. on bootstrap reset).
    case clear
}

// MARK: - Reducer

public let badgeFeedbackReducer: Reducer<BadgeFeedbackState, BadgeFeedbackAction> = { state, action in
    switch action {
    case let .ingest(badge, turnID, tier, at):
        state.ingest(badge: badge, turnID: turnID, tier: tier, at: at)

    case let .tick(at):
        let cutoff = at.addingTimeInterval(-state.visibleWindowSeconds)
        state.entries.removeAll { $0.receivedAt < cutoff }
        state.lastTickAt = at

    case .clear:
        state.entries = []
        state.lastTickAt = nil
    }
}
