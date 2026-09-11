import FluentWorkDiagnostics
import FluentWorkNetworking
import Foundation
import Testing
@testable import FluentWorkCore

@Test func speechSessionTimingsRecorderForwardsLogIDOnMarkAndTurnEnd() {
    let tracker = CapturingTracker()
    let recorder = SpeechSessionTimingsRecorder(
        tracker: tracker,
        clock: { Date(timeIntervalSince1970: 1) }
    )
    recorder.reset()
    recorder.setLogID("")
    recorder.setLogID(nil)
    recorder.setLogID("volc-abc123")
    recorder.setLogID("ignored-second")
    recorder.markTurnStarted("turn-1")
    recorder.mark(event: "ai_turn_end", properties: ["turn_id": "turn-1"])
    recorder.markTurnEnded("turn-1", source: "ios", stage: "ai_turn_end")

    #expect(recorder.logID() == "volc-abc123")

    let mark = tracker.events.first { $0.name == "timing_ai_turn_end" }
    #expect(mark?.properties["log_id"] == "volc-abc123")
    #expect(mark?.properties["turn_id"] == "turn-1")

    let duration = tracker.events.first { $0.name == "timing_turn_duration" }
    #expect(duration?.properties["log_id"] == "volc-abc123")
    #expect(duration?.properties["turn_id"] == "turn-1")
}

@Test func speechSessionTimingsRecorderMissingTurnStartEmitsMissingDuration() {
    let tracker = CapturingTracker()
    let recorder = SpeechSessionTimingsRecorder(
        tracker: tracker,
        clock: { Date(timeIntervalSince1970: 1) }
    )
    recorder.reset()
    recorder.markTurnEnded("turn-9", source: "ios", stage: "ai_turn_end")

    let duration = tracker.events.first { $0.name == "timing_turn_duration" }
    #expect(duration?.properties["turn_duration_ms"] == "missing")
    #expect(duration?.properties["log_id"] == nil)
}

@Test func speechSessionTimingsRecorderResetClearsLogIDAndTurnAnchors() {
    let tracker = CapturingTracker()
    let recorder = SpeechSessionTimingsRecorder(
        tracker: tracker,
        clock: { Date(timeIntervalSince1970: 1) }
    )
    recorder.reset()
    recorder.setLogID("volc-abc123")
    recorder.markTurnStarted("turn-1")
    recorder.reset()

    #expect(recorder.logID() == nil)
    recorder.markTurnEnded("turn-1", source: "ios", stage: "ai_turn_end")
    #expect(
        tracker.events.last { $0.name == "timing_turn_duration" }?
            .properties["turn_duration_ms"] == "missing"
    )
}

@Test func speechSessionTimingsRecorderConcurrentMarksStayConsistent() async {
    let tracker = CapturingTracker()
    let recorder = SpeechSessionTimingsRecorder(tracker: tracker)
    recorder.reset()

    await withTaskGroup(of: Void.self) { group in
        for index in 0..<32 {
            group.addTask {
                recorder.mark(event: "stage-\(index)")
            }
        }
    }

    let marks = tracker.events.filter { $0.name.hasPrefix("timing_stage-") }
    #expect(marks.count == 32)
    #expect(marks.allSatisfy { $0.properties["prev_event"] != nil })
}

@Test func speechSessionTimingsRecorderConcurrentSetLogIDKeepsFirst() async {
    let tracker = CapturingTracker()
    let recorder = SpeechSessionTimingsRecorder(tracker: tracker)
    recorder.reset()

    await withTaskGroup(of: Void.self) { group in
        for index in 0..<16 {
            group.addTask {
                recorder.setLogID("volc-\(index)")
            }
        }
    }

    let kept = recorder.logID()
    #expect(kept != nil)
    #expect(kept?.hasPrefix("volc-") == true)

    recorder.mark(event: "after")
    #expect(tracker.events.last?.properties["log_id"] == kept)
}

/// Production join: middleware `setLogID` from `ai.turn.end`, then the audio
/// loop keeps marking. Every later mark must carry that id.
@Test func speechSessionTimingsRecorderConcurrentMarksKeepSetLogID() async {
    let tracker = CapturingTracker()
    let recorder = SpeechSessionTimingsRecorder(tracker: tracker)
    recorder.reset()
    recorder.setLogID("volc-abc123")

    await withTaskGroup(of: Void.self) { group in
        for index in 0..<16 {
            group.addTask {
                recorder.mark(event: "vad-\(index)")
            }
        }
    }

    let marks = tracker.events.filter { $0.name.hasPrefix("timing_vad-") }
    #expect(marks.count == 16)
    #expect(marks.allSatisfy { $0.properties["log_id"] == "volc-abc123" })
}

/// Audio loop `markTurnStarted` and middleware `markTurnEnded` are per-turn.
/// Concurrent turns must not steal each other's anchors.
@Test func speechSessionTimingsRecorderConcurrentTurnsKeepOwnDuration() async {
    let tracker = CapturingTracker()
    let recorder = SpeechSessionTimingsRecorder(tracker: tracker)
    recorder.reset()

    await withTaskGroup(of: Void.self) { group in
        for index in 1...16 {
            group.addTask {
                let turnID = "turn-\(index)"
                recorder.markTurnStarted(turnID)
                recorder.markTurnEnded(turnID, source: "ios", stage: "ai_turn_end")
            }
        }
    }

    let durations = tracker.events.filter { $0.name == "timing_turn_duration" }
    #expect(durations.count == 16)
    #expect(durations.allSatisfy { $0.properties["turn_duration_ms"] != "missing" })
    let turnIDs = Set(durations.compactMap { $0.properties["turn_id"] })
    #expect(turnIDs.count == 16)
}

/// Duplicate `markTurnEnded` for the same turn (reconnect / double frame):
/// the first emits a duration, the rest emit `missing`.
@Test func speechSessionTimingsRecorderConcurrentDuplicateTurnEndIsIdempotent() async {
    let tracker = CapturingTracker()
    let recorder = SpeechSessionTimingsRecorder(tracker: tracker)
    recorder.reset()
    recorder.markTurnStarted("turn-1")

    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<8 {
            group.addTask {
                recorder.markTurnEnded("turn-1", source: "ios", stage: "ai_turn_end")
            }
        }
    }

    let durations = tracker.events.filter { $0.name == "timing_turn_duration" }
    #expect(durations.count == 8)
    let present = durations.filter { $0.properties["turn_duration_ms"] != "missing" }
    let missing = durations.filter { $0.properties["turn_duration_ms"] == "missing" }
    #expect(present.count == 1)
    #expect(missing.count == 7)
}

// MARK: - P1-5: first response

/// A clock the test moves by hand, so a latency can be asserted as a number
/// instead of as "greater than zero".
private final class SteppableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    func advance(seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
}

/// A streaming reply announces itself once per frame. Only the first one is the
/// assistant *starting* to answer — counting the rest would turn "how long until
/// the AI spoke" into "how long until it finished".
@Test func firstResponseIsReportedOncePerTurn() {
    let tracker = CapturingTracker()
    let clock = SteppableClock(Date(timeIntervalSince1970: 1_000))
    let recorder = SpeechSessionTimingsRecorder(tracker: tracker, clock: { clock.now })
    recorder.reset()
    recorder.markTurnStarted("turn-1")
    clock.advance(seconds: 0.25)

    recorder.markFirstResponse("turn-1", source: "text")
    recorder.markFirstResponse("turn-1", source: "text")
    recorder.markFirstResponse("turn-1", source: "text")

    let responses = tracker.events.filter { $0.name == "timing_first_response" }
    #expect(responses.count == 1)
    #expect(responses.first?.properties["first_response_ms"] == "250.000")
    #expect(responses.first?.properties["source"] == "text")
}

/// The audio path has no turn id to offer — binary frames carry a sequence and
/// nothing else — so it resolves to the turn most recently started.
@Test func firstResponseResolvesToTheLatestTurnWhenTheFrameCarriesNoID() {
    let tracker = CapturingTracker()
    let clock = SteppableClock(Date(timeIntervalSince1970: 1_000))
    let recorder = SpeechSessionTimingsRecorder(tracker: tracker, clock: { clock.now })
    recorder.reset()
    recorder.markTurnStarted("turn-7")
    clock.advance(seconds: 0.4)

    recorder.markFirstResponse(nil, source: "audio")

    let response = tracker.events.first { $0.name == "timing_first_response" }
    #expect(response?.properties["turn_id"] == "turn-7")
    #expect(response?.properties["source"] == "audio")
    #expect(response?.properties["first_response_ms"] == "400.000")
}

/// Without an offset the total is still reported and the split is **not**
/// invented: quoting `server_to_client_ms` from a raw subtraction would be
/// quoting the clock skew and calling it latency.
@Test func firstResponseWithoutAClockOffsetReportsOnlyTheTotal() {
    let tracker = CapturingTracker()
    let clock = SteppableClock(Date(timeIntervalSince1970: 1_000))
    let recorder = SpeechSessionTimingsRecorder(tracker: tracker, clock: { clock.now })
    recorder.reset()
    recorder.markTurnStarted("turn-1")
    clock.advance(seconds: 0.25)

    recorder.markFirstResponse("turn-1", source: "text", serverTsMs: 1_005_100)

    let response = tracker.events.first { $0.name == "timing_first_response" }
    #expect(response?.properties["first_response_ms"] == "250.000")
    #expect(response?.properties["server_to_client_ms"] == nil)
    #expect(response?.properties["clock_uncertainty_ms"] == nil)
}

@Test func firstResponseWithAClockOffsetSplitsServerTimeFromNetworkTime() {
    let tracker = CapturingTracker()
    let clock = SteppableClock(Date(timeIntervalSince1970: 1_000))
    let recorder = SpeechSessionTimingsRecorder(tracker: tracker, clock: { clock.now })
    recorder.reset()
    // Gateway 5 s fast, ±30 ms.
    recorder.setClockOffset(ClockOffset(milliseconds: 5_000, uncertaintyMs: 30, roundTripMs: 60))
    recorder.markTurnStarted("turn-1")
    // User stops speaking at local 1_000.000. The gateway stamps the first delta
    // at local 1_000.100 — its own clock reads 1_005.100 — and we read it at
    // local 1_000.250. So: 250 ms total, 100 ms uplink, 150 ms gateway→phone.
    clock.advance(seconds: 0.25)

    recorder.markFirstResponse("turn-1", source: "text", serverTsMs: 1_005_100)

    let response = tracker.events.first { $0.name == "timing_first_response" }
    #expect(response?.properties["first_response_ms"] == "250.000")
    #expect(response?.properties["server_to_client_ms"] == "150")
    #expect(response?.properties["clock_uncertainty_ms"] == "30")
    #expect(response?.properties["clock_offset_ms"] == "5000")
}

/// A missing anchor stays visible rather than being swallowed: reporting `0`
/// would read as a suspiciously perfect latency.
@Test func firstResponseWithoutATurnStartReportsMissing() {
    let tracker = CapturingTracker()
    let clock = SteppableClock(Date(timeIntervalSince1970: 1_000))
    let recorder = SpeechSessionTimingsRecorder(tracker: tracker, clock: { clock.now })
    recorder.reset()

    recorder.markFirstResponse("turn-9", source: "text")

    let response = tracker.events.first { $0.name == "timing_first_response" }
    #expect(response?.properties["first_response_ms"] == "missing")
}

/// The transport drops its estimate on disconnect; the recorder has to drop it
/// too, or a stale skew would keep being quoted against a socket it was never
/// measured on — and would never look wrong.
@Test func resetClearsTheClockOffsetSoAStaleSkewIsNotQuoted() {
    let tracker = CapturingTracker()
    let clock = SteppableClock(Date(timeIntervalSince1970: 1_000))
    let recorder = SpeechSessionTimingsRecorder(tracker: tracker, clock: { clock.now })
    recorder.reset()
    recorder.setClockOffset(ClockOffset(milliseconds: 5_000, uncertaintyMs: 30, roundTripMs: 60))
    recorder.reset()
    recorder.markTurnStarted("turn-1")
    clock.advance(seconds: 0.25)

    recorder.markFirstResponse("turn-1", source: "text", serverTsMs: 1_005_100)

    let response = tracker.events.first { $0.name == "timing_first_response" }
    #expect(response?.properties["server_to_client_ms"] == nil)
}

@Test func markTurnStartedReArmsFirstResponseForTheNextTurn() {
    let tracker = CapturingTracker()
    let clock = SteppableClock(Date(timeIntervalSince1970: 1_000))
    let recorder = SpeechSessionTimingsRecorder(tracker: tracker, clock: { clock.now })
    recorder.reset()
    recorder.markTurnStarted("turn-1")
    clock.advance(seconds: 0.25)
    recorder.markFirstResponse("turn-1", source: "text")
    recorder.markTurnEnded("turn-1", source: "ios", stage: "ai_turn_end")

    recorder.markTurnStarted("turn-2")
    clock.advance(seconds: 0.5)
    recorder.markFirstResponse("turn-2", source: "audio")

    let responses = tracker.events.filter { $0.name == "timing_first_response" }
    #expect(responses.count == 2)
    #expect(responses.compactMap { $0.properties["turn_id"] } == ["turn-1", "turn-2"])
    #expect(
        responses.compactMap { $0.properties["first_response_ms"] } == ["250.000", "500.000"]
    )
}
