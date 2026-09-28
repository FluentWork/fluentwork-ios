import FluentWorkNetworking
import Foundation
import Testing

@testable import FluentWorkCore

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try SessionHistoryJSON.makeDecoder().decode(T.self, from: Data(json.utf8))
}

@Test func aMinimalVerdictDecodesWithTheOptionalFieldsAbsent() throws {
    let verdict = try decode(
        DrillVerdict.self,
        """
        {"pass":false,"judge_reason":"语义不等价","judged":true,"success_streak":0,\
        "state":"new","next_due_at":"2026-09-29T00:02:04+08:00","recorded":true}
        """
    )

    #expect(verdict.pass == false)
    #expect(verdict.judgeReason == "语义不等价")
    #expect(verdict.judged)
    #expect(verdict.retryable == false)
    #expect(verdict.recordID == 0)
    #expect(verdict.promoted == false)
    #expect(verdict.asrText == "")
    #expect(verdict.canAppeal == false)
    #expect(verdict.needsConfirmation == false)
    #expect(verdict.nextDueAt == ISO8601DateFormatter().date(from: "2026-09-29T00:02:04+08:00"))
}

@Test func aVerdictDecodesWithAFractionalTimestamp() throws {
    let verdict = try decode(
        DrillVerdict.self,
        """
        {"pass":true,"judge_reason":"","judged":true,"retryable":false,"success_streak":3,\
        "state":"automated","next_due_at":"2026-09-29T00:02:04.78+08:00","recorded":true,\
        "record_id":42,"promoted":true,"asr_text":"Let's push the launch to next sprint."}
        """
    )

    #expect(verdict.pass)
    #expect(verdict.successStreak == 3)
    #expect(verdict.state == .automated)
    #expect(verdict.recordID == 42)
    #expect(verdict.promoted)
    #expect(verdict.asrText == "Let's push the launch to next sprint.")
    #expect(verdict.canAppeal)
}

@Test func anUnjudgedVerdictCannotBeAppealedEvenWhenItCarriesARecord() throws {
    let verdict = try decode(
        DrillVerdict.self,
        """
        {"pass":false,"judge_reason":"","judged":false,"retryable":true,"success_streak":0,\
        "state":"new","next_due_at":"2026-09-29T00:02:04Z","recorded":true,"record_id":9}
        """
    )

    #expect(verdict.needsConfirmation)
    #expect(verdict.retryable)
    #expect(verdict.canAppeal == false)
}

@Test func anUnrecordedVerdictCannotBeAppealed() throws {
    let verdict = try decode(
        DrillVerdict.self,
        """
        {"pass":false,"judge_reason":"","judged":true,"success_streak":1,\
        "state":"training","next_due_at":"2026-09-29T00:02:04Z","recorded":false,"record_id":0}
        """
    )

    #expect(verdict.canAppeal == false)
}

@Test func aRoundDecodesItsCards() throws {
    let round = try decode(
        DrillRound.self,
        """
        {"size":2,"cards":[\
        {"block_id":"b1","intent_zh":"要推迟一个已排期的需求",\
        "expression_en":"Let's push the launch to next sprint.","state":"new"},\
        {"block_id":"b2","intent_zh":"请求澄清","expression_en":"Could you clarify?","state":"training"}]}
        """
    )

    #expect(round.size == 2)
    #expect(round.cards.map(\.blockID) == ["b1", "b2"])
    #expect(round.cards[0].state == .new)
    #expect(round.cards[1].state == .training)
}

@Test func anUnknownBlockStateDecodesAsUnknownRatherThanFailing() throws {
    let round = try decode(
        DrillRound.self,
        """
        {"size":1,"cards":[{"block_id":"b1","intent_zh":"x","expression_en":"y","state":"retired"}]}
        """
    )

    #expect(round.cards[0].state == .unknown)
}

@Test func anAppealOutcomeDecodesItsFlags() throws {
    let outcome = try decode(
        DrillAppealOutcome.self,
        """
        {"record_id":42,"block_id":"b1","restored":true,"already_appealed":false,\
        "state":"training","success_streak":2,"next_due_at":"2026-09-29T00:02:04.5+08:00"}
        """
    )

    #expect(outcome.recordID == 42)
    #expect(outcome.blockID == "b1")
    #expect(outcome.restored)
    #expect(outcome.alreadyAppealed == false)
    #expect(outcome.successStreak == 2)
    #expect(outcome.note == nil)
}
