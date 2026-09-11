import FluentWorkCore
import Testing
@testable import FluentWorkUI

@Test func speakingRoomIdleStateShowsStartAction() {
    let model = SpeakingRoomViewModel(phase: .idle)

    #expect(model.controlState.title == "点击开始录音")
    #expect(model.controlState.showsProgress == false)
    #expect(
        model.controlState.primaryAction
            == .start(title: "开始录音", systemImage: "mic.circle.fill")
    )
}

@Test func speakingRoomProcessingASRStateShowsRecognizingTitle() {
    let model = SpeakingRoomViewModel(phase: .processing, processingStage: .asr)
    #expect(model.controlState.title == "识别中")
}

@Test func speakingRoomProcessingLLMStateShowsThinkingTitle() {
    let model = SpeakingRoomViewModel(phase: .processing, processingStage: .llm)
    #expect(model.controlState.title == "思考中")
}

@Test func speakingRoomProcessingReviewStateShowsReviewTitle() {
    let model = SpeakingRoomViewModel(phase: .processing, processingStage: .review)
    #expect(model.controlState.title == "生成评价中")
}

@Test func speakingRoomWaitingUserStateShowsTapToTalkByDefault() {
    let model = SpeakingRoomViewModel(phase: .waitingUser)

    #expect(model.controlState.title == "轮到你了")
    #expect(model.controlState.detail == "点一次开始说话，说完停顿一下会自动提交。")
    #expect(
        model.controlState.primaryAction
            == .start(title: "开始说话", systemImage: "mic.circle.fill")
    )
    #expect(model.startTapIntent == .beginTurn)
}

@Test func speakingRoomWaitingUserAutoVADHidesButton() {
    let model = SpeakingRoomViewModel(phase: .waitingUser, usesAutoVAD: true)

    #expect(model.controlState.detail == "直接开口说话即可，系统会自动开始识别。")
    #expect(model.controlState.primaryAction == nil)
    #expect(model.startTapIntent == .none)
}

@Test func speakingRoomRecordingStopSubmitsTurn() {
    let model = SpeakingRoomViewModel(phase: .recording)
    #expect(model.stopTapIntent == .endTurn)
    #expect(model.startTapIntent == .none)
}

@Test func speakingRoomWaitingForAIAnswerHidesHoldAfterAbort() {
    let model = SpeakingRoomViewModel(phase: .waitingForAIAnswer, usesAutoVAD: true)
    #expect(model.controlState.title == "本轮已超时")
    #expect(model.controlState.showsProgress == false)
    #expect(model.controlState.primaryAction == nil)
}

@Test func speakingRoomWaitingForAIAnswerManualShowsBeginTurn() {
    let model = SpeakingRoomViewModel(phase: .waitingForAIAnswer)
    #expect(model.controlState.title == "本轮已超时")
    #expect(model.startTapIntent == .beginTurn)
    #expect(
        model.controlState.primaryAction
            == .start(title: "开始说话", systemImage: "mic.circle.fill")
    )
}

/// The evaluation wait is not a blocking state — the machine lets the user open
/// the next turn from here — so it must not show a spinner *and* a start button
/// at the same time. Progress is reserved for phases with no action to offer.
@Test func speakingRoomWaitingForEvaluationOffersNextTurnWithoutProgress() {
    let model = SpeakingRoomViewModel(phase: .waitingForEvaluation, usesAutoVAD: true)
    #expect(model.controlState.title == "可以继续")
    #expect(model.controlState.detail == "这一轮的评价还在生成，也可以直接开口开始下一轮。")
    #expect(model.controlState.showsProgress == false)
    #expect(model.controlState.primaryAction == nil)
}

@Test func speakingRoomWaitingForEvaluationManualOffersStartButton() {
    let model = SpeakingRoomViewModel(phase: .waitingForEvaluation)
    #expect(model.controlState.title == "可以继续")
    #expect(model.controlState.showsProgress == false)
    #expect(
        model.controlState.primaryAction
            == .start(title: "开始说话", systemImage: "mic.circle.fill")
    )
}

/// Recording submits on a pause, so the button is an early submit rather than
/// the only way to end the turn.
@Test func speakingRoomRecordingOffersEarlySubmit() {
    let model = SpeakingRoomViewModel(phase: .recording)
    #expect(model.controlState.primaryAction
        == .stop(title: "说完了", systemImage: "checkmark.circle.fill"))
    #expect(model.controlState.detail?.contains("自动提交") == true)
}

@Test func speakingRoomEndedStateAllowsRestart() {
    let model = SpeakingRoomViewModel(phase: .ended)

    #expect(model.controlState.title == "本轮已结束")
    #expect(
        model.controlState.primaryAction
            == .start(title: "重新开始", systemImage: "arrow.clockwise.circle.fill")
    )
}

@Test func speakingRoomFailedStateSurfacesFailureReasonAndRetry() {
    let model = SpeakingRoomViewModel(
        phase: .failed,
        failureReason: "麦克风权限被拒绝"
    )

    #expect(model.controlState.title == "录音失败")
    #expect(model.controlState.detail == "麦克风权限被拒绝")
    #expect(
        model.controlState.primaryAction
            == .start(title: "重试", systemImage: "arrow.clockwise.circle.fill")
    )
}

@Test func speakingRoomPermissionGateReturnsGrantedState() async {
    let grantedGate = SpeakingRoomPermissionGate {
        true
    }
    let deniedGate = SpeakingRoomPermissionGate {
        false
    }

    let granted = await grantedGate.canStart()
    let denied = await deniedGate.canStart()

    #expect(granted == true)
    #expect(denied == false)
}
