import FluentWorkDiagnostics
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
