import FluentWorkNetworking
import Foundation
import Testing

@testable import FluentWorkCore

private let origin = Date(timeIntervalSince1970: 1_700_000_000)

private func card(_ id: String, intent: String = "要推迟一个已排期的需求") -> DrillCard {
    DrillCard(
        blockID: id,
        intentZH: intent,
        expressionEN: "Let's push the launch to next sprint.",
        state: .new
    )
}

private func round(_ ids: [String]) -> DrillRound {
    DrillRound(size: ids.count, cards: ids.map { card($0) })
}

private func verdict(
    pass: Bool,
    judged: Bool = true,
    retryable: Bool = false,
    recorded: Bool = true,
    recordID: Int64 = 7,
    promoted: Bool = false,
    asrText: String = "we need to do it later",
    reason: String = "缺少时间点"
) -> DrillVerdict {
    DrillVerdict(
        pass: pass,
        judgeReason: reason,
        judged: judged,
        retryable: retryable,
        successStreak: pass ? 1 : 0,
        state: pass ? .training : .new,
        nextDueAt: origin.addingTimeInterval(3600),
        recorded: recorded,
        recordID: recordID,
        promoted: promoted,
        asrText: asrText
    )
}

private func appeal(
    blockID: String,
    restored: Bool = true,
    alreadyAppealed: Bool = false,
    recordID: Int64 = 7
) -> DrillAppealOutcome {
    DrillAppealOutcome(
        recordID: recordID,
        blockID: blockID,
        restored: restored,
        alreadyAppealed: alreadyAppealed,
        state: .new,
        successStreak: 0,
        nextDueAt: origin
    )
}

@discardableResult
private func drive(
    _ state: inout DrillRoundState,
    _ events: DrillRoundEvent...
) -> [DrillRoundEffect] {
    var last: [DrillRoundEffect] = []
    for event in events {
        last = DrillRoundMachine.reduce(&state, event: event)
    }
    return last
}

@Test func startFetchesTheRound() {
    var state = DrillRoundState()
    let effects = DrillRoundMachine.reduce(&state, event: .start(size: 10))

    #expect(state.phase == .loading)
    #expect(effects == [.fetchRound(size: 10)])
}

@Test func anEmptyRoundIsAnEmptyStateNotAZeroQuestionRound() {
    var state = DrillRoundState()
    let effects = drive(&state, .start(size: 10), .roundLoaded(round([])))

    #expect(state.phase == .empty)
    #expect(state.planned == 0)
    #expect(state.current == nil)
    #expect(effects.isEmpty)
}

@Test func readinessComesBeforeTheAnswerClock() {
    var state = DrillRoundState()
    let loaded = drive(&state, .start(size: 10), .roundLoaded(round(["b1", "b2"])))

    #expect(state.phase == .ready)
    #expect(loaded == [.scheduleReadiness(seconds: 1)])

    let answering = drive(&state, .readinessElapsed(at: origin))
    #expect(state.phase == .answering)
    // ⚠️ 2026-10-02 改：进入作答**同时**发两个效应，顺序是「先采集、后定时器」。
    // 这不是顺手加的一条：稿子的两句话 ——「作答 5 秒**从开始录音起算**」与
    // 「response_ms 的计时起点是**准备期结束**」—— 只有在「录音就在准备期结束那一刻开始」
    // 时才同时成立。而这个数组正是那句设计在代码里的唯一落点。
    // 另一条理由是这里的顺序会被读法影响：`captureAnswer` 是正路，
    // `scheduleAnswerDeadline` 是「到点还没听清就带空文本提交」的兜底。
    #expect(
        answering == [
            .captureAnswer(seconds: 5),
            .scheduleAnswerDeadline(seconds: 5),
        ]
    )
}

/// 作答期间来的 `.attemptFailed` **被机器忽略** —— 这是「采集出错不该把这一轮判失败」的那张底。
///
/// 值得单独钉住，是因为它是**兜底而不是设计**：`reduce` 的 `default: return []` 恰好把它吞掉。
/// 哪天有人给 `.answering` 加一条 `attemptFailed` 分支（比如想让采集失败直接判失败），
/// 这条会红 —— 而那正是该有人拍的时候。
///
/// ⚠️ 反向那一半是必要的：少了它，「这个事件谁都不管」也能让上面那条通过。
@Test func anAttemptFailureWhileAnsweringIsIgnoredByTheMachine() {
    var state = DrillRoundState()
    _ = drive(&state, .start(size: 10), .roundLoaded(round(["b1"])), .readinessElapsed(at: origin))
    #expect(state.phase == .answering)

    let ignored = DrillRoundMachine.reduce(&state, event: .attemptFailed(message: "mic down"))
    #expect(ignored.isEmpty, "作答期间被判失败 —— 采集出错的那张兜底没了")
    #expect(state.phase == .answering)

    // 反向：**判定中**是接受的 —— 这条让「忽略」成为一个有边界的规则，而不是「没人管」。
    _ = drive(&state, .answerCaptured(asrText: "x", at: origin))
    #expect(state.phase == .judging)
    _ = DrillRoundMachine.reduce(&state, event: .attemptFailed(message: "boom"))
    #expect(state.phase == .failed(message: "boom"))
}

@Test func thePromptTypeCarriesNothingThatWouldGiveTheAnswerAway() {
    let prompt = DrillPrompt(card: card("b1"))

    #expect(prompt.intentZH == "要推迟一个已排期的需求")
    #expect(Mirror(reflecting: prompt).children.count == 2)
}

@Test func theRoundKnowsHowManyQuestionsItPlanned() {
    var state = DrillRoundState()
    drive(&state, .start(size: 10), .roundLoaded(round(["b1", "b2", "b3"])))

    #expect(state.planned == 3)
    #expect(state.position == 1)
    #expect(state.current?.blockID == "b1")
    #expect(state.queue.map(\.blockID) == ["b2", "b3"])
}

@Test func responseMsIsMeasuredFromTheEndOfReadiness() {
    var state = DrillRoundState()
    drive(&state, .start(size: 10), .roundLoaded(round(["b1", "b2"])), .readinessElapsed(at: origin))

    let effects = drive(
        &state,
        .answerCaptured(asrText: "push the launch later", at: origin.addingTimeInterval(3.2))
    )

    #expect(state.phase == .judging)
    #expect(
        effects == [
            .submitAttempt(
                blockID: "b1",
                asrText: "push the launch later",
                responseMS: 3200
            )
        ]
    )
}

@Test func aTimeoutSubmitsAnEmptyAttemptSoTheScheduleStillMoves() {
    var state = DrillRoundState()
    drive(&state, .start(size: 10), .roundLoaded(round(["b1", "b2"])), .readinessElapsed(at: origin))

    let effects = drive(&state, .answerDeadlineReached)

    #expect(state.phase == .judging)
    #expect(state.answeredAttempts == 1)
    #expect(effects == [.submitAttempt(blockID: "b1", asrText: "", responseMS: 5000)])
}

@Test func anUnjudgedVerdictIsNotAFailureAndStaysRetryable() {
    var state = DrillRoundState()
    drive(
        &state,
        .start(size: 10),
        .roundLoaded(round(["b1", "b2"])),
        .readinessElapsed(at: origin),
        .answerCaptured(asrText: "wat", at: origin.addingTimeInterval(1.5))
    )

    drive(&state, .verdictReceived(verdict(pass: false, judged: false, retryable: true)))

    #expect(state.phase == .verdict)
    #expect(state.awaitingConfirmation)
    #expect(state.unresolved.isEmpty)
    #expect(state.canAppeal == false)

    let effects = drive(&state, .retryTapped)
    #expect(state.phase == .judging)
    #expect(state.unresolved.isEmpty)
    #expect(effects == [.submitAttempt(blockID: "b1", asrText: "wat", responseMS: 1500)])
}

@Test func aPassedAttemptCountsAndIsNotLeftForReview() {
    var state = DrillRoundState()
    drive(
        &state,
        .start(size: 10),
        .roundLoaded(round(["b1", "b2"])),
        .readinessElapsed(at: origin),
        .answerCaptured(asrText: "x", at: origin),
        .verdictReceived(verdict(pass: true))
    )

    #expect(state.phase == .verdict)
    #expect(state.passedAttempts == 1)
    #expect(state.unresolved.isEmpty)
    #expect(state.awaitingConfirmation == false)
}

@Test func promotionShowsUpAsAnAutomatedDelta() {
    var state = DrillRoundState()
    drive(
        &state,
        .start(size: 10),
        .roundLoaded(round(["b1", "b2"])),
        .readinessElapsed(at: origin),
        .answerCaptured(asrText: "x", at: origin),
        .verdictReceived(verdict(pass: true, promoted: true))
    )

    #expect(state.automatedDelta == 1)
}

@Test func aFailedCardGoesToTheBackOfTheRoundOnce() {
    var state = DrillRoundState()
    drive(
        &state,
        .start(size: 10),
        .roundLoaded(round(["b1", "b2", "b3"])),
        .readinessElapsed(at: origin),
        .answerCaptured(asrText: "x", at: origin),
        .verdictReceived(verdict(pass: false))
    )

    #expect(state.unresolved == ["b1"])
    #expect(state.queue.map(\.blockID) == ["b2", "b3", "b1"])
    #expect(state.requeues["b1"] == 1)

    drive(&state, .advanceTapped, .readinessElapsed(at: origin), .answerCaptured(asrText: "x", at: origin))
    drive(&state, .verdictReceived(verdict(pass: false)))

    #expect(state.requeues["b2"] == 1)
    #expect(state.queue.filter { $0.blockID == "b2" }.count == 1)
}

@Test func skippingSubmitsAnEmptyAttemptAndRequeues() {
    var state = DrillRoundState()
    drive(&state, .start(size: 10), .roundLoaded(round(["b1", "b2"])), .readinessElapsed(at: origin))

    let effects = drive(&state, .skipTapped(at: origin.addingTimeInterval(1.2)))

    #expect(state.phase == .judging)
    #expect(state.requeues["b1"] == 1)
    #expect(state.queue.map(\.blockID) == ["b2", "b1"])
    #expect(effects == [.submitAttempt(blockID: "b1", asrText: "", responseMS: 1200)])
}

@Test func theRoundSettlesWhenTheQueueEmpties() {
    var state = DrillRoundState()
    drive(
        &state,
        .start(size: 10),
        .roundLoaded(round(["b1"])),
        .readinessElapsed(at: origin),
        .answerCaptured(asrText: "x", at: origin),
        .verdictReceived(verdict(pass: true))
    )
    #expect(state.phase == .verdict)

    drive(&state, .advanceTapped)
    #expect(state.phase == .settled)
    #expect(state.isSettled)
}

@Test func anAppealIsOnlyOfferedWhenTheAttemptWasRecorded() {
    var state = DrillRoundState()
    drive(
        &state,
        .start(size: 10),
        .roundLoaded(round(["b1", "b2"])),
        .readinessElapsed(at: origin),
        .answerCaptured(asrText: "x", at: origin),
        .verdictReceived(verdict(pass: false, recorded: false, recordID: 0))
    )

    #expect(state.canAppeal == false)
    #expect(drive(&state, .appealTapped).isEmpty)
    #expect(state.phase == .verdict)
}

@Test func aRestoredAppealUndoesTheAttemptLocally() {
    var state = DrillRoundState()
    drive(
        &state,
        .start(size: 10),
        .roundLoaded(round(["b1", "b2"])),
        .readinessElapsed(at: origin),
        .answerCaptured(asrText: "x", at: origin),
        .verdictReceived(verdict(pass: false))
    )
    #expect(state.unresolved == ["b1"])

    let effects = drive(&state, .appealTapped)
    #expect(effects == [.appeal(recordID: 7)])

    drive(&state, .appealResolved(appeal(blockID: "b1")))
    #expect(state.unresolved.isEmpty)
    #expect(state.answeredAttempts == 1)
    #expect(state.passedAttempts == 0)
}

@Test func aRestoredAppealRollsBackAPromotion() {
    var state = DrillRoundState()
    drive(
        &state,
        .start(size: 10),
        .roundLoaded(round(["b1", "b2"])),
        .readinessElapsed(at: origin),
        .answerCaptured(asrText: "x", at: origin),
        .verdictReceived(verdict(pass: true, promoted: true))
    )
    #expect(state.automatedDelta == 1)

    drive(&state, .appealTapped, .appealResolved(appeal(blockID: "b1")))
    #expect(state.automatedDelta == 0)
    #expect(state.passedAttempts == 0)
}

@Test func aSecondAppealChangesNothing() {
    var state = DrillRoundState()
    drive(
        &state,
        .start(size: 10),
        .roundLoaded(round(["b1", "b2"])),
        .readinessElapsed(at: origin),
        .answerCaptured(asrText: "x", at: origin),
        .verdictReceived(verdict(pass: false))
    )

    let before = state
    let effects = drive(
        &state,
        .appealResolved(appeal(blockID: "b1", restored: false, alreadyAppealed: true))
    )

    #expect(state == before)
    #expect(effects.isEmpty)
}

@Test func theRoundLengthIsThePlannedSizeEvenAfterRequeues() {
    var state = DrillRoundState()
    drive(
        &state,
        .start(size: 10),
        .roundLoaded(round(["b1", "b2"])),
        .readinessElapsed(at: origin),
        .answerCaptured(asrText: "x", at: origin),
        .verdictReceived(verdict(pass: false)),
        .advanceTapped,
        .readinessElapsed(at: origin),
        .answerCaptured(asrText: "x", at: origin),
        .verdictReceived(verdict(pass: false))
    )

    #expect(state.planned == 2)
    #expect(state.answeredAttempts == 2)
    #expect(state.queue.count == 2)
    #expect(state.phase == .verdict)
}
