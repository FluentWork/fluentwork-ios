import FluentWorkDiagnostics
import Foundation
import Testing
@testable import FluentWorkCore

@Test func speechSessionTimingsRecorderForwardsLogIDOnMarkAndTurnEnd() {
    let tracker = CapturingTracker()
    let recorder = SpeechSessionTimingsRecorder(tracker: tracker, clock: { Date(timeIntervalSince1970: 1) })
    recorder.reset()
    recorder.setLogID("")
    recorder.setLogID(nil)
    recorder.setLogID("volc-abc123")
    recorder.setLogID("ignored-second")
    recorder.markTurnStarted("turn-1")
    recorder.mark(event: "ai_turn_end", properties: ["turn_id": "turn-1"])
    recorder.markTurnEnded("turn-1", source: "ios", stage: "ai_turn_end")

    let mark = tracker.events.first { $0.name == "timing_ai_turn_end" }
    #expect(mark?.properties["log_id"] == "volc-abc123")
    #expect(mark?.properties["turn_id"] == "turn-1")

    let duration = tracker.events.first { $0.name == "timing_turn_duration" }
    #expect(duration?.properties["log_id"] == "volc-abc123")
    #expect(duration?.properties["turn_id"] == "turn-1")
}
