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

@Test func vadSpeechEndMovesRecordingToProcessingASR() {
    var state = SpeechSessionState(phase: .recording)
    _ = SpeechSessionMachine.reduce(&state, event: .vadSpeechEnd(turnID: nil))
    #expect(state.phase == .processingASR)
    #expect(state.processingSubStage == .asr)
    #expect(state.userTurnCount == 1)
}

@Test func serverASRReceivedMovesProcessingASRToProcessingLLM() {
    var state = SpeechSessionState(phase: .processingASR)
    _ = SpeechSessionMachine.reduce(
        &state,
        event: .serverASRReceived(text: "hello", turnID: "turn-1")
    )
    #expect(state.phase == .processingLLM)
    #expect(state.processingSubStage == .llm)
}

@Test func aiFirstAudioChunkMovesProcessingASRToAISpeaking() {
    var state = SpeechSessionState(phase: .processingASR)
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
    let ignored = SpeechSessionMachine.reduce(&state, event: .vadSpeechEnd(turnID: nil))
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

@Test func forceCloseFromWaitingUserEndsSession() {
    var state = SpeechSessionState(phase: .waitingUser)
    let effects = SpeechSessionMachine.reduce(&state, event: .forceClose)
    #expect(state.phase == .ended)
    #expect(state.isReconnecting == false)
    #expect(state.suspendedPhase == nil)
    #expect(effects.contains(.forceClose))
    #expect(effects.contains(.trackTransition(from: .waitingUser, to: .ended)))
}

@Test func forceCloseFromIdleIsNoOp() {
    var state = SpeechSessionState.initial
    let effects = SpeechSessionMachine.reduce(&state, event: .forceClose)
    #expect(state.phase == .idle)
    #expect(effects.isEmpty)
}

@Test func forceCloseFromRemainingActivePhasesEndsSession() {
    let phases: [SpeechSessionPhase] = [
        .aiSpeaking,
        .waitingUser,
        .recording,
        .processingASR,
        .processingLLM,
        .processingReview,
        .waitingForAIAnswer,
        .waitingForEvaluation,
        .degradedText,
    ]
    for phase in phases {
        var state = SpeechSessionState(phase: phase)
        let effects = SpeechSessionMachine.reduce(&state, event: .forceClose)
        #expect(state.phase == .ended, "expected ended from \(phase)")
        #expect(state.isReconnecting == false, "expected reconnect cleared from \(phase)")
        #expect(state.suspendedPhase == nil, "expected suspend cleared from \(phase)")
        #expect(effects.contains(.forceClose), "expected forceClose effect from \(phase)")
    }
}

@Test func forceCloseWhileSuspendedEndsSession() {
    var state = SpeechSessionState(phase: .recording)
    _ = SpeechSessionMachine.reduce(&state, event: .interruptedBySystem)
    #expect(state.suspendedPhase == .recording)

    let effects = SpeechSessionMachine.reduce(&state, event: .forceClose)
    #expect(state.phase == .ended)
    #expect(state.suspendedPhase == nil)
    #expect(state.isReconnecting == false)
    #expect(effects.contains(.forceClose))
}

@Test func speechSessionPhaseIsActiveMatchesLivePhases() {
    #expect(SpeechSessionPhase.connecting.isActive)
    #expect(SpeechSessionPhase.waitingUser.isActive)
    #expect(SpeechSessionPhase.processingASR.isActive)
    #expect(SpeechSessionPhase.processingLLM.isActive)
    #expect(SpeechSessionPhase.processingReview.isActive)
    #expect(SpeechSessionPhase.waitingForAIAnswer.isActive)
    #expect(SpeechSessionPhase.waitingForEvaluation.isActive)
    #expect(!SpeechSessionPhase.idle.isActive)
    #expect(!SpeechSessionPhase.ended.isActive)
    #expect(!SpeechSessionPhase.failed.isActive)
}

@Test func speechSessionPhaseLabelsCoverV20WaitsAndExistingStages() {
    #expect(SpeechSessionPhase.waitingForAIAnswer.label == "waiting_for_ai_answer")
    #expect(SpeechSessionPhase.waitingForEvaluation.label == "waiting_for_evaluation")
    #expect(SpeechSessionPhase.waitingForAIAnswer.stageTag == "waiting_for_ai_answer")
    #expect(SpeechSessionPhase.waitingForEvaluation.stageTag == "waiting_for_evaluation")
    #expect(SpeechSessionPhase.waitingForAIAnswer.processingSubStage == nil)
    #expect(SpeechSessionPhase.waitingForEvaluation.processingSubStage == nil)
    #expect(!SpeechSessionPhase.waitingForAIAnswer.isProcessing)
    #expect(!SpeechSessionPhase.waitingForEvaluation.isProcessing)

    let labels = Dictionary(uniqueKeysWithValues: SpeechSessionPhase.allCases.map { ($0, $0.label) })
    #expect(labels[.idle] == "idle")
    #expect(labels[.connecting] == "orchestration")
    #expect(labels[.waitingUser] == "waiting_user")
    #expect(labels[.recording] == "vad_capture")
    #expect(labels[.processingASR] == "asr")
    #expect(labels[.processingLLM] == "llm")
    #expect(labels[.processingReview] == "review")
    #expect(labels[.aiSpeaking] == "tts")
    #expect(labels[.degradedText] == "text_fallback")
    #expect(labels[.ended] == "ended")
    #expect(labels[.failed] == "failed")
    #expect(Set(labels.values).count == SpeechSessionPhase.allCases.count)
}

@Test func illegalCombinationsAreIgnored() {
    let cases: [(SpeechSessionPhase, SpeechSessionEvent)] = [
        (.idle, .socketReady),
        (.idle, .vadSpeechStart),
        (.failed, .socketReady),
        (.failed, .networkLost),
        (.ended, .sessionStartTap),
        (.processingASR, .vadSpeechStart),
        (.processingASR, .recordingTimedOut),
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

    _ = SpeechSessionMachine.reduce(&state, event: .holdEnd(turnID: nil))
    #expect(state.phase == .processingASR)
}

@Test func aiTurnEndHappyPathReturnsToWaitingForEvaluation() {
    var state = SpeechSessionState(phase: .aiSpeaking)
    let effects = SpeechSessionMachine.reduce(&state, event: .aiTurnEnd)
    #expect(state.phase == .waitingForEvaluation)
    #expect(effects.contains(.trackTransition(from: .aiSpeaking, to: .waitingForEvaluation)))
}

@Test func aiTurnEndFromProcessingASRReturnsToWaitingForEvaluation() {
    var state = SpeechSessionState(phase: .processingASR)
    let effects = SpeechSessionMachine.reduce(&state, event: .aiTurnEnd)
    #expect(state.phase == .waitingForEvaluation)
    #expect(state.processingSubStage == nil)
    #expect(effects.contains(.trackTransition(from: .processingASR, to: .waitingForEvaluation)))
}

@Test func processingSubStageReachedMovesLLMToReview() {
    var state = SpeechSessionState(phase: .processingLLM)
    _ = SpeechSessionMachine.reduce(&state, event: .processingSubStageReached(.review))
    #expect(state.phase == .processingReview)
    #expect(state.processingSubStage == .review)
}

@Test func duplicateSocketReadyWhileProcessingASRIsIdempotent() {
    var state = SpeechSessionState(phase: .processingASR, isReconnecting: true)
    let effects = SpeechSessionMachine.reduce(&state, event: .socketReady)
    #expect(state.phase == .processingASR)
    #expect(state.isReconnecting == false)
    #expect(effects.isEmpty)
}

@Test func processingTimeoutsUseCompileTimeDefaults() {
    let timeouts = ProcessingTimeouts.standard
    #expect(timeouts.asr == .seconds(15))
    #expect(timeouts.llm == .seconds(45))
    #expect(timeouts.review == .seconds(30))
    #expect(timeouts.totalCap == .seconds(70))
}

@Test func recordingTimedOutAbortsTurnWithoutFailingSession() {
    var state = SpeechSessionState(phase: .recording)
    let effects = SpeechSessionMachine.reduce(&state, event: .recordingTimedOut)

    #expect(state.phase == .waitingForAIAnswer)
    #expect(state.processingSubStage == nil)
    #expect(state.userTurnCount == 1)
    #expect(state.lastTurnOutcome == .timeout)
    #expect(state.failureReason == nil)
    #expect(effects.contains(.sendTurnAbort(turnID: "turn-1", outcome: .timeout)))
    #expect(effects.contains(.trackTransition(from: .recording, to: .waitingForAIAnswer)))
    #expect(!effects.contains(.turnTimeoutExpired))
    #expect(!effects.contains(.endSession))
}

@Test func recordingTimedOutWhileSuspendedStillAbortsTurn() {
    var state = SpeechSessionState(phase: .recording)
    _ = SpeechSessionMachine.reduce(&state, event: .interruptedBySystem)
    #expect(state.suspendedPhase == .recording)

    let effects = SpeechSessionMachine.reduce(&state, event: .recordingTimedOut)
    #expect(state.phase == .waitingForAIAnswer)
    #expect(effects.contains(.sendTurnAbort(turnID: "turn-1", outcome: .timeout)))
}

@Test func recordingTimedOutFromWaitingUserIsNoOp() {
    var state = SpeechSessionState(phase: .waitingUser)
    let before = state
    let effects = SpeechSessionMachine.reduce(&state, event: .recordingTimedOut)
    #expect(state == before)
    #expect(effects.isEmpty)
}

@Test func vadSpeechEndAfterRecordingDoesNotSendTurnAbort() {
    var state = SpeechSessionState(phase: .recording)
    let effects = SpeechSessionMachine.reduce(&state, event: .vadSpeechEnd(turnID: nil))
    #expect(state.phase == .processingASR)
    #expect(state.lastTurnOutcome == .ok)
    #expect(!effects.contains(.sendTurnAbort(turnID: "turn-1", outcome: .timeout)))
}

@Test func holdEndAfterRecordingRecordsOkOutcome() {
    var state = SpeechSessionState(phase: .recording)
    let effects = SpeechSessionMachine.reduce(&state, event: .holdEnd(turnID: nil))
    #expect(state.phase == .processingASR)
    #expect(state.lastTurnOutcome == .ok)
    #expect(effects.allSatisfy {
        if case .sendTurnAbort = $0 { return false }
        return true
    })
}

@Test func endTapFromRecordingAbortsAsUserAbandoned() {
    var state = SpeechSessionState(phase: .recording)
    let effects = SpeechSessionMachine.reduce(&state, event: .endTap)

    #expect(state.phase == .ended)
    #expect(state.lastTurnOutcome == .userAbandoned)
    #expect(state.userTurnCount == 1)
    #expect(effects.contains(.sendTurnAbort(turnID: "turn-1", outcome: .userAbandoned)))
    #expect(effects.contains(.endSession))
}

@Test func forceCloseFromRecordingAbortsAsUserAbandoned() {
    var state = SpeechSessionState(phase: .recording)
    let effects = SpeechSessionMachine.reduce(&state, event: .forceClose)

    #expect(state.phase == .ended)
    #expect(state.lastTurnOutcome == .userAbandoned)
    #expect(effects.contains(.sendTurnAbort(turnID: "turn-1", outcome: .userAbandoned)))
    #expect(effects.contains(.forceClose))
}

@Test func failedFromRecordingAbortsAsError() {
    var state = SpeechSessionState(phase: .recording)
    let effects = SpeechSessionMachine.reduce(&state, event: .failed("network"))

    #expect(state.phase == .failed)
    #expect(state.lastTurnOutcome == .error)
    #expect(state.failureReason == "network")
    #expect(effects.contains(.sendTurnAbort(turnID: "turn-1", outcome: .error)))
    #expect(effects.contains(.endSession))
}

@Test func networkLostFromRecordingAbortsAsErrorAndLeavesRecording() {
    var state = SpeechSessionState(phase: .recording)
    let effects = SpeechSessionMachine.reduce(&state, event: .networkLost)

    #expect(state.phase == .waitingUser)
    #expect(state.lastTurnOutcome == .error)
    #expect(state.isReconnecting)
    #expect(effects.contains(.sendTurnAbort(turnID: "turn-1", outcome: .error)))
    #expect(effects.contains(.startReconnectWindow))
}

@Test func networkDegradedFromRecordingAbortsAsError() {
    var state = SpeechSessionState(phase: .recording)
    let effects = SpeechSessionMachine.reduce(&state, event: .networkDegraded)

    #expect(state.phase == .degradedText)
    #expect(state.lastTurnOutcome == .error)
    #expect(effects.contains(.sendTurnAbort(turnID: "turn-1", outcome: .error)))
}

@Test func turnOutcomeRawValuesMatchWireContract() {
    #expect(TurnOutcome.ok.rawValue == "ok")
    #expect(TurnOutcome.timeout.rawValue == "timeout")
    #expect(TurnOutcome.userAbandoned.rawValue == "user_abandoned")
    #expect(TurnOutcome.error.rawValue == "error")
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

@Test func waitingForAIAnswerAcceptsNextUtterance() {
    var state = SpeechSessionState(phase: .recording)
    _ = SpeechSessionMachine.reduce(&state, event: .recordingTimedOut)
    #expect(state.phase == .waitingForAIAnswer)

    let effects = SpeechSessionMachine.reduce(&state, event: .vadSpeechStart)
    #expect(state.phase == .recording)
    #expect(effects.contains(.trackTransition(from: .waitingForAIAnswer, to: .recording)))
}

@Test func waitingForAIAnswerEndTapEndsSession() {
    var state = SpeechSessionState(phase: .waitingForAIAnswer)
    let effects = SpeechSessionMachine.reduce(&state, event: .endTap)
    #expect(state.phase == .ended)
    #expect(effects.contains(.endSession))
    #expect(effects.contains(.trackTransition(from: .waitingForAIAnswer, to: .ended)))
}

@Test func evaluationReceivedLeavesWaitingForEvaluation() {
    var state = SpeechSessionState(phase: .waitingForEvaluation)
    let effects = SpeechSessionMachine.reduce(&state, event: .evaluationReceived)
    #expect(state.phase == .waitingUser)
    #expect(effects.contains(.trackTransition(from: .waitingForEvaluation, to: .waitingUser)))
}

@Test func waitingForEvaluationEndTapEndsSession() {
    var state = SpeechSessionState(phase: .waitingForEvaluation)
    let effects = SpeechSessionMachine.reduce(&state, event: .endTap)
    #expect(state.phase == .ended)
    #expect(effects.contains(.endSession))
}

@Test func waitingForEvaluationVadStartsNextTurn() {
    var state = SpeechSessionState(phase: .waitingForEvaluation)
    let effects = SpeechSessionMachine.reduce(&state, event: .vadSpeechStart)
    #expect(state.phase == .recording)
    #expect(effects.contains(.trackTransition(from: .waitingForEvaluation, to: .recording)))
}

@Test func isValidTransitionAcceptsLiveGraphAndRejectsIllegalHops() {
    #expect(SpeechSessionMachine.isValidTransition(from: .idle, to: .connecting))
    #expect(SpeechSessionMachine.isValidTransition(from: .waitingUser, to: .recording))
    #expect(SpeechSessionMachine.isValidTransition(from: .recording, to: .processingASR))
    #expect(SpeechSessionMachine.isValidTransition(from: .processingASR, to: .aiSpeaking))
    #expect(SpeechSessionMachine.isValidTransition(from: .aiSpeaking, to: .waitingForEvaluation))
    #expect(SpeechSessionMachine.isValidTransition(from: .recording, to: .waitingForAIAnswer))
    #expect(SpeechSessionMachine.isValidTransition(from: .waitingForAIAnswer, to: .ended))
    #expect(SpeechSessionMachine.isValidTransition(from: .waitingForEvaluation, to: .waitingUser))
    #expect(SpeechSessionMachine.isValidTransition(from: .waitingForEvaluation, to: .ended))
    #expect(!SpeechSessionMachine.isValidTransition(from: .idle, to: .aiSpeaking))
    #expect(!SpeechSessionMachine.isValidTransition(from: .waitingForEvaluation, to: .idle))
    #expect(!SpeechSessionMachine.isValidTransition(from: .ended, to: .waitingUser))
    #expect(!SpeechSessionMachine.isValidTransition(from: .idle, to: .idle))
}
