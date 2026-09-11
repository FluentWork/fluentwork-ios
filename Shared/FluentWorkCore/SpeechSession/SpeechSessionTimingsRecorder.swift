import FluentWorkDiagnostics
import FluentWorkNetworking
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
        /// Most recently started turn. Turns are serial, so this is the turn a
        /// frame without a `turn_id` belongs to — the audio path carries no id
        /// of its own (binary frames hold a sequence, nothing more).
        var latestTurnID: String?
        /// Turns whose first response has already been reported.
        ///
        /// The metric is "how long until the assistant started answering", and
        /// the answer arrives once per turn — but the frames that announce it
        /// (`ai.text.delta`, the first audio chunk) repeat. Without this the
        /// first delta would report the latency and every following delta would
        /// report a slightly larger one, turning a p50 into a p50 of the last
        /// frame of every reply.
        var firstResponseReported: Set<String> = []
        /// Latest gateway↔phone clock estimate (P1-5), or `nil` when no ping
        /// round trip has completed. `nil` means "not measurable" — never
        /// "offset is zero", which would bill the clock skew to the latency.
        var clockOffset: ClockOffset?
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
            $0.firstResponseReported.removeAll()
            // The transport drops its own estimate on disconnect, so keeping
            // this one would let a stale skew outlive the socket it was measured
            // against. A fresh round trip re-establishes it within one RTT.
            $0.clockOffset = nil
            $0.vendorLogID = nil
        }
    }

    /// P1-5: stores the latest gateway↔phone clock estimate.
    ///
    /// Fed from `.diagnostic(.clockOffsetEstimated)` — the transport owns the
    /// round trip, this recorder only consumes the result. Passing `nil` puts
    /// the recorder back to "not measurable".
    public func setClockOffset(_ offset: ClockOffset?) {
        storage.withLock { $0.clockOffset = offset }
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
        storage.withLock {
            $0.turnStartTimes[turnID] = now
            $0.latestTurnID = turnID
            $0.firstResponseReported.remove(turnID)
        }
    }

    /// P1-5: records how long after the user stopped speaking the assistant
    /// produced its first output, and — when a clock offset is known — how much
    /// of that was the gateway→phone hop.
    ///
    /// Anchored on ``markTurnStarted``, deliberately, rather than on the
    /// previous ``mark(event:properties:)``. The ASR relay lands between the two
    /// and is marked, so a delta against "the last mark" would quietly measure
    /// from the transcript instead of from the user's last word — the number
    /// would still look like a latency, and would be wrong by the ASR hop, which
    /// is exactly the hop a reader would then conclude was fast.
    ///
    /// - Parameters:
    ///   - turnID: the turn this response belongs to. `nil` resolves to the most
    ///     recently started turn — the audio path has no id to offer, since
    ///     binary frames carry only a sequence.
    ///   - source: `"text"` or `"audio"` — which channel answered first.
    ///   - serverTsMs: `server_ts_ms` from the frame, when it carried one. This
    ///     is what splits the total into "server thought for X" and "network
    ///     took Y"; without it only the total is reported.
    public func markFirstResponse(
        _ turnID: String?,
        source: String,
        serverTsMs: Int64? = nil
    ) {
        let now = clock()
        let nowMs = Int64((now.timeIntervalSince1970 * 1000).rounded())

        let snapshot = storage.withLock {
            state -> (turnID: String, startedAt: Date?, offset: ClockOffset?, logID: String?)? in
            guard let resolved = turnID ?? state.latestTurnID else { return nil }
            // Once per turn. The frames that announce a first response keep
            // coming; reporting each would make the metric the latency of the
            // *last* frame of every reply.
            guard !state.firstResponseReported.contains(resolved) else { return nil }
            state.firstResponseReported.insert(resolved)
            return (resolved, state.turnStartTimes[resolved], state.clockOffset, state.vendorLogID)
        }
        guard let snapshot else { return }

        var props = [
            "turn_id": snapshot.turnID,
            "source": source,
            // A missing anchor stays visible instead of being swallowed:
            // `first_response_ms=missing` says the turn began without a marker,
            // which is a bug worth seeing. Reporting `0` here would read as a
            // suspiciously perfect latency.
            "first_response_ms": snapshot.startedAt.map {
                Self.format(now.timeIntervalSince($0) * 1000)
            } ?? "missing",
        ]
        if let logID = snapshot.logID {
            props["log_id"] = logID
        }
        // Only when both halves are present. Quoting a server-side split with
        // no offset would be quoting the clock skew and calling it latency.
        if let offset = snapshot.offset, let serverTsMs {
            props["server_to_client_ms"] = String(
                offset.oneWayLatencyMs(serverMs: serverTsMs, localReceiveMs: nowMs)
            )
            props["clock_uncertainty_ms"] = String(offset.uncertaintyMs)
            props["clock_offset_ms"] = String(offset.milliseconds)
        }
        tracker.track(event: "timing_first_response", properties: props)
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
            state.firstResponseReported.remove(turnID)
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
