import Foundation

/// Display text for the conversation list.
///
/// This lives in core rather than in the view for two reasons. It is the only
/// part of a row with a right answer — `154 秒` and `2 分 34 秒` are both
/// readable and only one is what a person wants to read — and it is testable
/// here. `FluentWorkUI` formats nothing today and has no `DateFormatter`
/// anywhere; keeping the date work out of it is what keeps that true.
public enum SessionHistoryFormatting {

    /// `154` → `"2 分 34 秒"`.
    ///
    /// Zero is spelled out rather than shown as `0 秒`: a session whose
    /// duration is zero is one that was created and then abandoned, and `0 秒`
    /// reads like a measurement that failed.
    public static func duration(_ seconds: Int) -> String {
        guard seconds > 0 else { return "不足 1 秒" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes == 0 { return "\(remainder) 秒" }
        if remainder == 0 { return "\(minutes) 分" }
        return "\(minutes) 分 \(remainder) 秒"
    }

    /// `今天 14:32` / `昨天 14:32` / `9月10日 14:32` / `2025年9月10日 14:32`.
    ///
    /// The calendar is a parameter so a test can pin a time zone and a "now"
    /// and get one answer on every machine. Nothing here goes through
    /// `DateFormatter`: the format strings are literal Chinese, so the locale
    /// would have to be forced to make them stable anyway, and reading the
    /// components off the calendar is both shorter and immune to the
    /// `Sendable` problem that `ISO8601DateFormatter` created next door in
    /// `SessionHistoryJSON`.
    public static func startedAt(
        _ date: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let clock = clockTime(date, calendar: calendar)

        if calendar.isDate(date, inSameDayAs: now) {
            return "今天 \(clock)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天 \(clock)"
        }

        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        let year = calendar.component(.year, from: date)
        if year == calendar.component(.year, from: now) {
            return "\(month)月\(day)日 \(clock)"
        }
        return "\(year)年\(month)月\(day)日 \(clock)"
    }

    /// Backend `practice_sessions.status` — `internal/session/types.go` has
    /// `created` / `active` / `ended` / `abandoned` / `reviewed`.
    ///
    /// An unrecognised value is passed through **as itself** rather than
    /// flattened to 未知. This is a vocabulary the backend owns and has already
    /// grown once; a new value appearing raw on the one row that has it is a
    /// readable signal, while 未知 on that row would say nothing about which
    /// row it is.
    public static func status(_ raw: String) -> String {
        switch raw {
        case "created": return "未开始"
        case "active": return "进行中"
        case "ended": return "已结束"
        case "abandoned": return "已中断"
        case "reviewed": return "已回顾"
        default: return raw
        }
    }

    private static func clockTime(_ date: Date, calendar: Calendar) -> String {
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        return String(format: "%02d:%02d", hour, minute)
    }
}
