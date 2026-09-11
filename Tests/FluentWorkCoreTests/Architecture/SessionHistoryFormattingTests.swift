import Foundation
import Testing
@testable import FluentWorkCore

/// Pinned so the answer is the same on a laptop in Shanghai and a CI runner in
/// UTC. Every call below passes this calendar explicitly — a default of
/// `.current` would make these tests pass locally and fail in CI, which is the
/// kind of failure that gets a test deleted rather than fixed.
private let fixedCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar
}()

private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
    fixedCalendar.date(
        from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
    )!
}

@Suite("Session history formatting")
struct SessionHistoryFormattingTests {

    /// The row's second line, and the most-read string in the list. `0 秒`
    /// would read like a measurement that failed rather than a session that
    /// never got going.
    @Test func durationReadsAsMinutesAndSeconds() {
        #expect(SessionHistoryFormatting.duration(0) == "不足 1 秒")
        #expect(SessionHistoryFormatting.duration(45) == "45 秒")
        #expect(SessionHistoryFormatting.duration(60) == "1 分")
        #expect(SessionHistoryFormatting.duration(154) == "2 分 34 秒")
        #expect(SessionHistoryFormatting.duration(3600) == "60 分")
    }

    /// 今天／昨天 are *calendar* words, not "within 24 hours". A session at
    /// 23:50 is 昨天 to someone opening the app at 00:30, forty minutes later,
    /// and calling it 今天 would be wrong in the one case where it matters.
    @Test func todayAndYesterdayAreCalendarDaysNotTwentyFourHours() {
        let justAfterMidnight = at(2026, 9, 12, 0, 30)
        #expect(
            SessionHistoryFormatting.startedAt(
                at(2026, 9, 11, 23, 50),
                now: justAfterMidnight,
                calendar: fixedCalendar
            ) == "昨天 23:50"
        )
        #expect(
            SessionHistoryFormatting.startedAt(
                at(2026, 9, 12, 0, 10),
                now: justAfterMidnight,
                calendar: fixedCalendar
            ) == "今天 00:10"
        )
    }

    /// The year is dropped when it is obvious and kept when it is not.
    @Test func olderDatesLoseTheYearAndOlderYearsKeepIt() {
        let now = at(2026, 9, 12, 14, 0)
        #expect(
            SessionHistoryFormatting.startedAt(
                at(2026, 9, 10, 14, 32),
                now: now,
                calendar: fixedCalendar
            ) == "9月10日 14:32"
        )
        #expect(
            SessionHistoryFormatting.startedAt(
                at(2025, 9, 10, 14, 32),
                now: now,
                calendar: fixedCalendar
            ) == "2025年9月10日 14:32"
        )
    }

    /// Minutes are zero-padded, hours are not. `9:5` is not a time.
    @Test func clockTimeIsZeroPadded() {
        #expect(
            SessionHistoryFormatting.startedAt(
                at(2026, 9, 12, 9, 5),
                now: at(2026, 9, 12, 12, 0),
                calendar: fixedCalendar
            ) == "今天 09:05"
        )
    }

    /// The vocabulary belongs to the backend. A value this build has never
    /// heard of is passed through rather than flattened to 未知 — on a row
    /// that has nothing else to say about itself, the raw value is the only
    /// thing distinguishing it from its neighbours.
    @Test func unknownStatusesPassThroughInsteadOfBecomingUnknown() {
        #expect(SessionHistoryFormatting.status("ended") == "已结束")
        #expect(SessionHistoryFormatting.status("abandoned") == "已中断")
        #expect(SessionHistoryFormatting.status("reviewed") == "已回顾")
        #expect(SessionHistoryFormatting.status("archived") == "archived")
    }
}
