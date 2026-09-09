import Foundation
import Testing
@testable import FluentWorkCore

@Test func testTurnTimeout_TriggersAbortFrame() {
    var state = SpeechSessionState(phase: .recording)
    let effects = SpeechSessionMachine.reduce(&state, event: .recordingTimedOut)

    #expect(state.phase == .waitingUser)
    #expect(effects.contains(.sendTurnAbort(turnID: "turn-1", outcome: .timeout)))
    #expect(!effects.contains(.turnTimeoutExpired))
    #expect(!effects.contains(.endSession))
}

@Test func testOutcome_OkOnNormalEnd() {
    var state = SpeechSessionState(phase: .recording)
    _ = SpeechSessionMachine.reduce(&state, event: .vadSpeechEnd(turnID: nil))
    #expect(state.lastTurnOutcome == .ok)
}

@Test func testOutcome_TimeoutOn60s() {
    var state = SpeechSessionState(phase: .recording)
    _ = SpeechSessionMachine.reduce(&state, event: .recordingTimedOut)
    #expect(state.lastTurnOutcome == .timeout)
}

@Test func testOutcome_UserAbandonedOnCancel() {
    var state = SpeechSessionState(phase: .recording)
    _ = SpeechSessionMachine.reduce(&state, event: .endTap)
    #expect(state.lastTurnOutcome == .userAbandoned)
}

@Test func testOutcome_ErrorOnNetworkFail() {
    var state = SpeechSessionState(phase: .recording)
    _ = SpeechSessionMachine.reduce(&state, event: .failed("network"))
    #expect(state.lastTurnOutcome == .error)
}

@Test func testSystemPromptBuilder_With8Hits() {
    let hits = (1...8).map { index in
        RecordedHit(id: "b-\(index)", intentZh: "意图\(index)", chunkEn: "chunk \(index)")
    }
    let built = SystemPromptBuilder.build(
        basePrompt: "base",
        recentHits: hits,
        userLevel: .beginner
    )
    #expect(built.contains("- 意图1: chunk 1"))
    #expect(built.contains("- 意图8: chunk 8"))
}

@Test func testSystemPromptBuilder_WithoutHits() {
    let built = SystemPromptBuilder.build(
        basePrompt: "base",
        recentHits: [],
        userLevel: .beginner
    )
    #expect(!built.contains("最近用户命中过的话术块"))
    #expect(built.hasPrefix("base"))
}

@Test func testSystemPromptBuilder_UserLevelAdvanced() {
    let built = SystemPromptBuilder.build(
        basePrompt: "base",
        recentHits: [],
        userLevel: .advanced
    )
    #expect(built.contains("## 用户水平:advanced"))
}
