import Foundation
import Testing
@testable import FluentWorkCore

@Test func sessionStartTapFromIdleCreatesSessionEffect() {
    var state = SpeechSessionState.initial
    let effects = SpeechSessionMachine.reduce(&state, event: .sessionStartTap)

    #expect(state.phase == .connecting)
    #expect(effects.contains(.createSession))
    #expect(effects.contains(.trackTransition(from: .idle, to: .connecting)))
}

@Test func socketReadyMovesConnectingToAISpeaking() {
    var state = SpeechSessionState(phase: .connecting)
    let effects = SpeechSessionMachine.reduce(&state, event: .socketReady)

    #expect(state.phase == .aiSpeaking)
    #expect(effects.contains(.trackTransition(from: .connecting, to: .aiSpeaking)))
}

@Test func duplicateSocketReadyWhileActiveIsIdempotent() {
    var state = SpeechSessionState(phase: .aiSpeaking, isReconnecting: true)
    let effects = SpeechSessionMachine.reduce(&state, event: .socketReady)

    #expect(state.phase == .aiSpeaking)
    #expect(state.isReconnecting == false)
    #expect(effects.isEmpty)
}

@Test func vadDuringAISpeakingTriggersInterruptSideEffects() {
    var state = SpeechSessionState(phase: .aiSpeaking)
    let effects = SpeechSessionMachine.reduce(&state, event: .vadSpeechStart)

    #expect(state.phase == .recording)
    #expect(effects.contains(.stopPlayback))
    #expect(effects.contains(.sendInterrupt))
}

@Test func vadSpeechEndMovesRecordingToProcessing() {
    var state = SpeechSessionState(phase: .recording)
    _ = SpeechSessionMachine.reduce(&state, event: .vadSpeechEnd)
    #expect(state.phase == .processing)
}

@Test func aiFirstAudioChunkMovesProcessingToAISpeaking() {
    var state = SpeechSessionState(phase: .processing)
    _ = SpeechSessionMachine.reduce(&state, event: .aiFirstAudioChunk)
    #expect(state.phase == .aiSpeaking)
}

@Test func networkDegradedEntersDegradedTextImmediately() {
    var state = SpeechSessionState(phase: .waitingUser)
    let effects = SpeechSessionMachine.reduce(&state, event: .networkDegraded)

    #expect(state.phase == .degradedText)
    #expect(state.isReconnecting == false)
    #expect(effects.contains(.trackTransition(from: .waitingUser, to: .degradedText)))
}

@Test func networkLostStartsReconnectWindowWithoutLeavingPhase() {
    var state = SpeechSessionState(phase: .waitingUser)
    let effects = SpeechSessionMachine.reduce(&state, event: .networkLost)

    #expect(state.phase == .waitingUser)
    #expect(state.isReconnecting)
    #expect(effects.contains(.startReconnectWindow))
}

@Test func reconnectTimeoutEntersDegradedText() {
    var state = SpeechSessionState(phase: .waitingUser, isReconnecting: true)
    let effects = SpeechSessionMachine.reduce(&state, event: .reconnectTimedOut)

    #expect(state.phase == .degradedText)
    #expect(state.isReconnecting == false)
    #expect(effects.contains(.trackTransition(from: .waitingUser, to: .degradedText)))
}

@Test func systemInterruptSuspendsThenResumesToWaitingUser() {
    var state = SpeechSessionState(phase: .recording)
    let suspendEffects = SpeechSessionMachine.reduce(&state, event: .interruptedBySystem)
    #expect(state.phase == .recording)
    #expect(state.suspendedPhase == .recording)
    #expect(suspendEffects.contains(.stopPlayback))

    // Active events are ignored while suspended.
    let ignored = SpeechSessionMachine.reduce(&state, event: .vadSpeechEnd)
    #expect(state.phase == .recording)
    #expect(state.suspendedPhase == .recording)
    #expect(ignored.isEmpty)

    let resumeEffects = SpeechSessionMachine.reduce(&state, event: .systemInterruptEnded)
    #expect(state.phase == .waitingUser)
    #expect(state.suspendedPhase == nil)
    #expect(resumeEffects.contains(.trackTransition(from: .recording, to: .waitingUser)))
}

@Test func systemInterruptFromDegradedTextPreservesDegradedText() {
    var state = SpeechSessionState(phase: .degradedText)
    _ = SpeechSessionMachine.reduce(&state, event: .interruptedBySystem)
    #expect(state.suspendedPhase == .degradedText)

    _ = SpeechSessionMachine.reduce(&state, event: .systemInterruptEnded)
    #expect(state.phase == .degradedText)
    #expect(state.suspendedPhase == nil)
}

@Test func systemInterruptEndedIsNoOpWithoutSuspend() {
    var state = SpeechSessionState(phase: .degradedText)
    let effects = SpeechSessionMachine.reduce(&state, event: .systemInterruptEnded)
    #expect(state.phase == .degradedText)
    #expect(effects.isEmpty)
}

@Test func endTapEndsActiveSession() {
    var state = SpeechSessionState(phase: .waitingUser)
    let effects = SpeechSessionMachine.reduce(&state, event: .endTap)
    #expect(state.phase == .ended)
    #expect(effects.contains(.endSession))
}

@Test func illegalCombinationsAreIgnored() {
    let cases: [(SpeechSessionPhase, SpeechSessionEvent)] = [
        (.idle, .socketReady),
        (.idle, .vadSpeechStart),
        (.failed, .socketReady),
        (.failed, .networkLost),
        (.ended, .sessionStartTap),
        (.processing, .vadSpeechStart),
        (.waitingUser, .aiFirstAudioChunk),
    ]

    for (phase, event) in cases {
        var state = SpeechSessionState(phase: phase, failureReason: phase == .failed ? "x" : nil)
        let before = state
        let effects = SpeechSessionMachine.reduce(&state, event: event)
        #expect(state == before, "expected no-op for \(phase) + \(event)")
        #expect(effects.isEmpty, "expected no effects for \(phase) + \(event)")
    }
}

@Test func interruptRaceVadThenAITurnEndLeavesRecording() {
    var state = SpeechSessionState(phase: .aiSpeaking)
    _ = SpeechSessionMachine.reduce(&state, event: .vadSpeechStart)
    #expect(state.phase == .recording)

    let effects = SpeechSessionMachine.reduce(&state, event: .aiTurnEnd)
    #expect(state.phase == .recording)
    #expect(effects.isEmpty)
}

@Test func holdStartFromWaitingUserStartsRecording() {
    var state = SpeechSessionState(phase: .waitingUser)
    _ = SpeechSessionMachine.reduce(&state, event: .holdStart)
    #expect(state.phase == .recording)

    _ = SpeechSessionMachine.reduce(&state, event: .holdEnd)
    #expect(state.phase == .processing)
}

@Test func aiTurnEndHappyPathReturnsToWaitingUser() {
    var state = SpeechSessionState(phase: .aiSpeaking)
    let effects = SpeechSessionMachine.reduce(&state, event: .aiTurnEnd)
    #expect(state.phase == .waitingUser)
    #expect(effects.contains(.trackTransition(from: .aiSpeaking, to: .waitingUser)))
}

@Test func aiTurnEndFromProcessingReturnsToWaitingUser() {
    var state = SpeechSessionState(phase: .processing)
    let effects = SpeechSessionMachine.reduce(&state, event: .aiTurnEnd)
    #expect(state.phase == .waitingUser)
    #expect(effects.contains(.trackTransition(from: .processing, to: .waitingUser)))
}

@Test func reconnectSucceededClearsReconnectFlag() {
    var state = SpeechSessionState(phase: .waitingUser, isReconnecting: true)
    let effects = SpeechSessionMachine.reduce(&state, event: .reconnectSucceeded)
    #expect(state.phase == .waitingUser)
    #expect(state.isReconnecting == false)
    #expect(effects.isEmpty)
}

@Test func failedEventCapturesReason() {
    var state = SpeechSessionState(phase: .connecting)
    let effects = SpeechSessionMachine.reduce(&state, event: .failed("网络错误"))
    #expect(state.phase == .failed)
    #expect(state.failureReason == "网络错误")
    #expect(effects.contains(.trackTransition(from: .connecting, to: .failed)))
    #expect(effects.contains(.endSession))
}

@Test func degradedTextLoopKeepsPhaseOnSendAndReply() {
    var state = SpeechSessionState(phase: .degradedText)
    let sendEffects = SpeechSessionMachine.reduce(&state, event: .textMessageSent)
    #expect(state.phase == .degradedText)
    #expect(sendEffects.contains(.sendTextMessage))

    let replyEffects = SpeechSessionMachine.reduce(&state, event: .textReplyReceived)
    #expect(state.phase == .degradedText)
    #expect(replyEffects.isEmpty)
}
