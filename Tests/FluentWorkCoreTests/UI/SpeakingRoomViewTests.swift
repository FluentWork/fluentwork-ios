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

@Test func speakingRoomWaitingUserStateShowsInstructionWithoutButton() {
    let model = SpeakingRoomViewModel(phase: .waitingUser)

    #expect(model.controlState.title == "轮到你了")
    #expect(model.controlState.detail == "直接开口说话即可，系统会自动开始识别。")
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
