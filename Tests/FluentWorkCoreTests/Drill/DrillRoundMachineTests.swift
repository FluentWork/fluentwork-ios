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
    #expect(answering == [.scheduleAnswerDeadline(seconds: 5)])
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
