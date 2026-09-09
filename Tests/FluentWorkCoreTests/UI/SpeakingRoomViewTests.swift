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
    let model = SpeakingRoomViewModel(phase: .processingASR)
    #expect(model.controlState.title == "识别中")
}

@Test func speakingRoomProcessingLLMStateShowsThinkingTitle() {
    let model = SpeakingRoomViewModel(phase: .processingLLM)
    #expect(model.controlState.title == "思考中")
}

@Test func speakingRoomProcessingReviewStateShowsReviewTitle() {
    let model = SpeakingRoomViewModel(phase: .processingReview)
    #expect(model.controlState.title == "生成评价中")
}

@Test func speakingRoomWaitingUserStateShowsInstructionWithoutButton() {
    let model = SpeakingRoomViewModel(phase: .waitingUser)

    #expect(model.controlState.title == "轮到你了")
    #expect(model.controlState.detail == "直接开口说话即可，系统会自动开始识别。")
    #expect(model.controlState.primaryAction == nil)
}

@Test func speakingRoomWaitingForAIAnswerHidesHoldAndShowsProgress() {
    let model = SpeakingRoomViewModel(phase: .waitingForAIAnswer)
    #expect(model.controlState.title == "AI 思考中…")
    #expect(model.controlState.showsProgress == true)
    #expect(model.controlState.primaryAction == nil)
}

@Test func speakingRoomWaitingForEvaluationHidesHoldAndShowsProgress() {
    let model = SpeakingRoomViewModel(phase: .waitingForEvaluation)
    #expect(model.controlState.title == "正在评价本次表现…")
    #expect(model.controlState.showsProgress == true)
    #expect(model.controlState.primaryAction == nil)
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
