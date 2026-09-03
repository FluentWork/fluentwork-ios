import Foundation
import FluentWorkDiagnostics

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
/// The recorder uses an unfair lock because the audio-loop side reads
/// timestamps off a Sendable boundary and the middleware side writes them
/// from a synchronous middleware closure. AllocatedUnfairLock keeps both
/// call sites lock-safe without crossing actor hops.
public final class SpeechSessionTimingsRecorder: @unchecked Sendable {
    private let tracker: TrackerClientProtocol
    private let clock: () -> Date
    private let lock = NSLock()
    private var startTime: Date?
    private var lastMarkTime: Date?
    private var lastEvent: String?
    private var turnStartTimes: [String: Date] = [:]
    // B15-I3: vendor log_id captured from the first ai.turn.end frame.
    // Forwarded to all subsequent tracker events so the iOS trace can be
    // correlated with the backend and vendor-side logs.
    private var vendorLogID: String?

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
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        startTime = now
        lastMarkTime = now
        lastEvent = nil
        turnStartTimes.removeAll()
        vendorLogID = nil
    }

    /// B15-I3: stores the vendor log_id extracted from the first ai.turn.end frame.
    /// Once set, all subsequent `mark()` calls automatically include `log_id`
    /// in the tracker properties so the full iOS trace can be correlated with
    /// the backend and Volcengine diagnostic logs.
    public func setLogID(_ logID: String?) {
        lock.lock()
        defer { lock.unlock() }
        if vendorLogID == nil {
            vendorLogID = logID
        }
    }

    /// Returns the current vendor log_id, if set.
    public func logID() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return vendorLogID
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
        let snapshot: (deltaMs: Double?, totalMs: Double?, prev: String?) = lock.locked {
            let delta = lastMarkTime.map { now.timeIntervalSince($0) * 1000 }
            let total = startTime.map { now.timeIntervalSince($0) * 1000 }
            let prev = lastEvent
            self.lastMarkTime = now
            self.lastEvent = event
            return (delta, total, prev)
        }

        var props = properties
        if let deltaMs = snapshot.deltaMs {
            props["delta_ms"] = Self.format(deltaMs)
        }
        if let totalMs = snapshot.totalMs {
            props["total_ms"] = Self.format(totalMs)
        }
        props["prev_event"] = snapshot.prev ?? "none"
        // B15-I3: include vendor log_id in every tracker event so the full iOS
        // trace can be joined with backend and vendor logs on log_id.
        if let logID = lock.locked({ vendorLogID }) {
            props["log_id"] = logID
        }

        tracker.track(event: "timing_\(event)", properties: props)
    }

    /// Anchors the start of a turn so we can later emit a per-turn `turn_duration_ms`
    /// when the matching `markTurnEnded` runs. Kept separate from `mark` so the
    /// audio-loop and middleware writers don't have to share a single
    /// chronological index.
    public func markTurnStarted(_ turnID: String) {
        lock.lock()
        defer { lock.unlock() }
        turnStartTimes[turnID] = clock()
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
        let startedAt: Date? = lock.locked {
            defer { turnStartTimes.removeValue(forKey: turnID) }
            return turnStartTimes[turnID]
        }

        let durationMs: String
        if let startedAt {
            durationMs = Self.format(now.timeIntervalSince(startedAt) * 1000)
        } else {
            durationMs = "missing"
        }

        tracker.track(
            event: "timing_turn_duration",
            properties: [
                "turn_id": turnID,
                "source": source,
                "stage": stage,
                "turn_duration_ms": durationMs,
            ]
        )
    }

    private static func format(_ ms: Double) -> String {
        // Three-decimal precision matches the granularity backend timing logs
        // emit on `voice session ended` (sub-millisecond detail for short
        // stages, e.g. audio decode) without flooding the tracker with noise.
        String(format: "%.3f", ms)
    }
}

private extension NSLock {
    /// Convenience: run `body` while the lock is held and return its value.
    /// Mirrors `OSAllocatedUnfairLock.withLock` semantics so the recorder's
    /// readers can grab a tuple snapshot without writing unlock ceremony at
    /// every call site.
    func locked<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}