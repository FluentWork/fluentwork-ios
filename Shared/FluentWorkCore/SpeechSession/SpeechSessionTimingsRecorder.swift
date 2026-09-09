import FluentWorkDiagnostics
import Foundation
import os

/// Records elapsed time between speech-session milestones so iOS logs match
/// the backend's `stage` timing stamps (`orchestration` / `asr` / etc.).
///
/// Every `mark(event:properties:)` call emits a `timing_<event>` tracker entry
/// with three structured properties so the iOS side can be diffed against the
/// backend session_start / session_end timing samples:
///
///   - `delta_ms` — wall-clock milliseconds since the previous mark
///   - `total_ms` — wall-clock milliseconds since `reset()` (session start)
///   - `prev_event` — name of the previous mark, so stage-to-stage jumps are
///     diffable from the backend's `voice session ended` duration fields
///
/// Sync API on purpose: middleware writes from a sync `Middleware` closure
/// and the audio loop reads from a `Sendable` `.task`. Apple
/// `OSAllocatedUnfairLock` (iOS 16+) replaces `NSLock` here — same as
/// `TurnCountBox` / `SpeechCaptureGate`.
public final class SpeechSessionTimingsRecorder: @unchecked Sendable {
    private struct State {
        var startTime: Date?
        var lastMarkTime: Date?
        var lastEvent: String?
        var turnStartTimes: [String: Date] = [:]
        /// B15-I3: vendor log_id from the first `ai.turn.end`.
        var vendorLogID: String?
    }

    private let tracker: TrackerClientProtocol
    private let clock: @Sendable () -> Date
    private let storage = OSAllocatedUnfairLock(initialState: State())

    public init(
        tracker: TrackerClientProtocol,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.tracker = tracker
        self.clock = clock
    }

    /// Resets the timeline. Call on session start (`.sessionStartTap`) and on
    /// session reconnect so per-turn deltas stay anchored to the new epoch.
    public func reset() {
        let now = clock()
        storage.withLock {
            $0.startTime = now
            $0.lastMarkTime = now
            $0.lastEvent = nil
            $0.turnStartTimes.removeAll()
            $0.vendorLogID = nil
        }
    }

    /// B15-I3: stores the vendor log_id extracted from the first ai.turn.end frame.
    /// Once set, all subsequent `mark()` calls automatically include `log_id`
    /// in the tracker properties so the full iOS trace can be correlated with
    /// the backend and Volcengine diagnostic logs.
    public func setLogID(_ logID: String?) {
        guard let logID, !logID.isEmpty else { return }
        storage.withLock {
            if $0.vendorLogID == nil {
                $0.vendorLogID = logID
            }
        }
    }

    /// Returns the current vendor log_id, if set.
    public func logID() -> String? {
        storage.withLock { $0.vendorLogID }
    }

    /// Records a milestone and emits `timing_<event>` with `delta_ms` /
    /// `total_ms` / `prev_event` properties. Caller-supplied `properties`
    /// are merged on top so the iOS log can carry turn_id / source / stage
    /// tags alongside the timing columns.
    public func mark(
        event: String,
        properties: [String: String] = [:]
    ) {
        let now = clock()
        let snapshot = storage.withLock { state -> (deltaMs: Double?, totalMs: Double?, prev: String?, logID: String?) in
            let delta = state.lastMarkTime.map { now.timeIntervalSince($0) * 1000 }
            let total = state.startTime.map { now.timeIntervalSince($0) * 1000 }
            let prev = state.lastEvent
            let logID = state.vendorLogID
            state.lastMarkTime = now
            state.lastEvent = event
            return (delta, total, prev, logID)
        }

        var props = properties
        if let deltaMs = snapshot.deltaMs {
            props["delta_ms"] = Self.format(deltaMs)
        }
        if let totalMs = snapshot.totalMs {
            props["total_ms"] = Self.format(totalMs)
        }
        props["prev_event"] = snapshot.prev ?? "none"
        if let logID = snapshot.logID {
            props["log_id"] = logID
        }

        tracker.track(event: "timing_\(event)", properties: props)
    }

    /// Anchors the start of a turn so we can later emit a per-turn `turn_duration_ms`
    /// when the matching `markTurnEnded` runs. Kept separate from `mark` so the
    /// audio-loop and middleware writers don't have to share a single
    /// chronological index.
    public func markTurnStarted(_ turnID: String) {
        let now = clock()
        storage.withLock { $0.turnStartTimes[turnID] = now }
    }

    /// Emits the per-turn duration and clears the turn anchor. Idempotent: a
    /// missing turn anchor (e.g. start was missed because of a fast reconnect)
    /// emits `turn_duration_ms=missing` instead of swallowing the marker.
    public func markTurnEnded(
        _ turnID: String,
        source: String,
        stage: String
    ) {
        let now = clock()
        let snapshot = storage.withLock { state -> (startedAt: Date?, logID: String?) in
            let startedAt = state.turnStartTimes.removeValue(forKey: turnID)
            return (startedAt, state.vendorLogID)
        }

        let durationMs: String
        if let startedAt = snapshot.startedAt {
            durationMs = Self.format(now.timeIntervalSince(startedAt) * 1000)
        } else {
            durationMs = "missing"
        }

        var props = [
            "turn_id": turnID,
            "source": source,
            "stage": stage,
            "turn_duration_ms": durationMs,
        ]
        if let logID = snapshot.logID {
            props["log_id"] = logID
        }
        tracker.track(event: "timing_turn_duration", properties: props)
    }

    private static func format(_ ms: Double) -> String {
        // Three-decimal precision matches the granularity backend timing logs
        // emit on `voice session ended` (sub-millisecond detail for short
        // stages, e.g. audio decode) without flooding the tracker with noise.
        String(format: "%.3f", ms)
    }
}
