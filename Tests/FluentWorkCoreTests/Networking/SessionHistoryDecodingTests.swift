import FluentWorkNetworking
import Foundation
import Testing

/// The first DTO in this repo to carry a `Date`, and the date is the whole
/// story: the backend marshals Go's `time.Time`, which is RFC3339Nano **with a
/// variable fraction** — Go drops trailing zeros, so the same field arrives
/// with and without one.
///
/// Neither obvious answer survives that, and both fail *silently on the rows
/// that look fine*: a bare `JSONDecoder()` wants a number, and Codable's
/// `.iso8601` strategy rejects fractional seconds. A hand-written fixture with
/// round timestamps would pass while production broke — which is why both
/// shapes are pinned here rather than one.
@Suite("Session history decoding")
struct SessionHistoryDecodingTests {

    private let pageJSON = """
    {
      "items": [
        {
          "session_id": "7cb815fe-d6fd-49be-8a79-005573c7d646",
          "scene_type": "voice",
          "status": "ended",
          "started_at": "2026-09-12T00:02:04.78+08:00",
          "duration_sec": 154
        },
        {
          "session_id": "5c02f7b8-fecd-4491-a9aa-eec2c7e23221",
          "scene_type": "voice",
          "status": "ended",
          "started_at": "2026-09-12T00:09:05+08:00",
          "duration_sec": 0
        }
      ],
      "next_cursor": "MjAyNi0wOS0xMg==",
      "size": 20
    }
    """

    @Test func decodesBothShapesOfTimestampTheBackendProduces() throws {
        let page = try SessionHistoryJSON.makeDecoder()
            .decode(SessionHistoryPage.self, from: Data(pageJSON.utf8))

        #expect(page.items.count == 2)
        #expect(page.size == 20)
        #expect(page.nextCursor == "MjAyNi0wOS0xMg==")

        // Asserted through UTC calendar parts rather than a hand-computed
        // epoch: `00:02:04.78+08:00` is `16:02:04.78Z` on the previous day,
        // which is a transformation that can be checked by reading it.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let withFraction = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: page.items[0].startedAt
        )
        #expect(withFraction.year == 2026)
        #expect(withFraction.month == 9)
        #expect(withFraction.day == 11)
        #expect(withFraction.hour == 16)
        #expect(withFraction.minute == 2)
        #expect(withFraction.second == 4)

        // The fraction is the whole point of this test: `.iso8601` rejects the
        // row outright, and a decoder that silently dropped it would still pass
        // every assertion above.
        let fraction = page.items[0].startedAt.timeIntervalSince1970
            .truncatingRemainder(dividingBy: 1)
        #expect(abs(fraction - 0.78) < 0.001, "the fractional seconds survived")

        // And the row without one still decodes and lands on a whole second.
        let plainFraction = page.items[1].startedAt.timeIntervalSince1970
            .truncatingRemainder(dividingBy: 1)
        #expect(abs(plainFraction) < 0.001)
    }

    @Test func decodesTheRowFields() throws {
        let page = try SessionHistoryJSON.makeDecoder()
            .decode(SessionHistoryPage.self, from: Data(pageJSON.utf8))

        #expect(page.items[0].sessionID == "7cb815fe-d6fd-49be-8a79-005573c7d646")
        #expect(page.items[0].sceneType == "voice")
        #expect(page.items[0].durationSec == 154)
        // `material_id` is absent on both rows and must stay absent, not fail:
        // it is a B21 placeholder the backend omits until materials land.
        #expect(page.items[0].materialID == nil)
    }

    /// A page whose rows are all there and whose cursor is absent is the end of
    /// the list, not a decoding failure — `next_cursor` is `omitempty` on the
    /// backend.
    @Test func decodesAnEmptyPageWithNoCursor() throws {
        let json = #"{"items": [], "size": 20}"#
        let page = try SessionHistoryJSON.makeDecoder()
            .decode(SessionHistoryPage.self, from: Data(json.utf8))

        #expect(page.items.isEmpty)
        #expect(page.nextCursor == nil)
    }

    /// A timestamp that is neither shape must be a loud failure with the value
    /// in it — not a `nil` date and not a decoder that quietly guesses.
    @Test func rejectsATimestampThatIsNeitherShape() {
        let json = #"{"items": [{"session_id": "s", "scene_type": "voice", "status": "ended", "started_at": "yesterday", "duration_sec": 1}], "size": 20}"#

        #expect(throws: DecodingError.self) {
            _ = try SessionHistoryJSON.makeDecoder()
                .decode(SessionHistoryPage.self, from: Data(json.utf8))
        }
    }
}
