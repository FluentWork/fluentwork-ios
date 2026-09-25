import Testing
@testable import FluentWorkCore

/// B8：提示要同时满足两个前提。
///
/// 「静默窗口到了」与「轮到用户」是两件事，分开断言是因为它们各自都可能被写错：
/// 只看窗口，用户说到一半按钮会冒出来；只看轮次，AI 刚闭嘴按钮就出现 —— 那正是
/// PRD §5.4 风险表点名的「用户会**等**梯子而不是先尝试」。
@Test func theRescueOfferNeedsBothTheElapsedWindowAndTheFloor() {
    var due = SpeakingRoomState(phase: .waitingUser)
    due.isRescueHintDue = true
    #expect(due.isRescueHintAvailable)

    var windowNotElapsed = SpeakingRoomState(phase: .waitingUser)
    windowNotElapsed.isRescueHintDue = false
    #expect(!windowNotElapsed.isRescueHintAvailable)

    var speaking = SpeakingRoomState(phase: .recording)
    speaking.isRescueHintDue = true
    #expect(!speaking.isRescueHintAvailable)

    var aiSpeaking = SpeakingRoomState(phase: .aiSpeaking)
    aiSpeaking.isRescueHintDue = true
    #expect(!aiSpeaking.isRescueHintAvailable)

    var ended = SpeakingRoomState(phase: .ended)
    ended.isRescueHintDue = true
    #expect(!ended.isRescueHintAvailable)
}

/// 还在等徽章时，轮次已经交回用户了 —— 只是评分没到，AI 也不会再说话。
@Test func theEvaluationStageCountsAsTheUsersFloor() {
    var evaluating = SpeakingRoomState(phase: .processing, processingStage: .evaluation)
    evaluating.isRescueHintDue = true
    #expect(evaluating.isRescueHintAvailable)
}

/// `.aiAnswer` 不是用户的轮次：那一轮是用户中途放弃的，AI 的答案还在路上。
@Test func theAbandonedTurnsAnswerStageIsNotTheUsersFloor() {
    var answering = SpeakingRoomState(phase: .processing, processingStage: .aiAnswer)
    answering.isRescueHintDue = true
    #expect(!answering.isRescueHintAvailable)
}

@Test func armingAndTappingEachPutTheStoredFlagAway() {
    var state = SpeakingRoomState(phase: .waitingUser, isRescueHintDue: true)
    #expect(state.isRescueHintAvailable)

    speakingRoomReducer(&state, .rescueHintArmed)
    #expect(!state.isRescueHintDue)

    speakingRoomReducer(&state, .rescueHintBecameDue)
    #expect(state.isRescueHintAvailable)

    speakingRoomReducer(&state, .rescueHintTapped)
    #expect(!state.isRescueHintDue)
}

/// 用户开口，状态机把轮次收回去 —— 提示的闸门正是靠这一步关上的。
///
/// 这条钉的是「谁负责关门」：提示自己不清场，清场的是状态机。如果提示另写一份
/// 清零点，用户说到一半按钮就会冒出来，而两份清零点迟早会漂开。
@Test func theMachineTakesTheFloorBackWhenTheUserStartsSpeaking() {
    var state = SpeakingRoomState(phase: .waitingUser, isRescueHintDue: true)
    #expect(state.isRescueHintAvailable)

    SpeechSessionMachine.reduce(&state.session, event: .vadSpeechStart)

    #expect(state.phase == .recording)
    #expect(!state.isRescueHintAvailable)
}

/// 进房间要把窗口清掉，和这一臂里其它房间级状态一样。
@Test func enteringTheRoomClearsTheWindow() {
    var state = SpeakingRoomState(phase: .idle, isRescueHintDue: true)

    speakingRoomReducer(&state, .enterRoom(continueFrom: nil))

    #expect(!state.isRescueHintDue)
}
