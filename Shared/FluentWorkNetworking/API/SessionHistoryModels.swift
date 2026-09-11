import Foundation

/// `GET /api/v1/sessions` — the conversation list (backend B24,
/// `internal/sessionhistory/model.go`).
public struct SessionHistoryItem: Codable, Equatable, Sendable, Identifiable {
    public let sessionID: String
    public let sceneType: String
    public let status: String
    public let startedAt: Date
    public let durationSec: Int
    /// B21 placeholder on the backend too — present in the contract, empty
    /// until the materials module lands.
    public let materialID: String?

    public var id: String { sessionID }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case sceneType = "scene_type"
        case status
        case startedAt = "started_at"
        case durationSec = "duration_sec"
        case materialID = "material_id"
    }

    public init(
        sessionID: String,
        sceneType: String,
        status: String,
        startedAt: Date,
        durationSec: Int,
        materialID: String? = nil
    ) {
        self.sessionID = sessionID
        self.sceneType = sceneType
        self.status = status
        self.startedAt = startedAt
        self.durationSec = durationSec
        self.materialID = materialID
    }
}

/// One cursor page of the list. `nextCursor` absent means the end.
public struct SessionHistoryPage: Codable, Equatable, Sendable {
    public let items: [SessionHistoryItem]
    public let nextCursor: String?
    public let size: Int

    enum CodingKeys: String, CodingKey {
        case items
        case size
        case nextCursor = "next_cursor"
    }

    public init(items: [SessionHistoryItem], nextCursor: String? = nil, size: Int) {
        self.items = items
        self.nextCursor = nextCursor
        self.size = size
    }
}

/// One transcript turn of a past session — `GET /api/v1/sessions/:id`,
/// `SessionDetail.utterances`.
///
/// `speaker` is a bare `String` on the wire (`"user"` / `"ai"`) because that is
/// what the backend sends, and it is kept as one here for the same reason
/// `status` is: a third speaker appearing should show up as itself rather than
/// fail to decode.
public struct SessionUtterance: Codable, Equatable, Sendable, Identifiable {
    public let seq: Int
    public let speaker: String
    public let text: String

    public var id: Int { seq }

    public init(seq: Int, speaker: String, text: String) {
        self.seq = seq
        self.speaker = speaker
        self.text = text
    }
}

/// `GET /api/v1/sessions/:id`.
///
/// Carries the whole row the list has plus `materials` / `utterances` /
/// `review`. Only `utterances` is decoded: they are what "重现那一场" means, and
/// the rest already has a surface — `materials` is a B21 placeholder that is
/// empty by its own comment, and `review` is rendered in full by the review
/// page, which is one tap away from the room. Decoding a second copy of the
/// evaluation here would be two places that can drift about what a session
/// scored.
public struct SessionDetail: Codable, Equatable, Sendable {
    public let sessionID: String
    public let sceneType: String
    public let status: String
    public let startedAt: Date
    public let durationSec: Int
    public let materialID: String?
    public let utterances: [SessionUtterance]

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case sceneType = "scene_type"
        case status
        case startedAt = "started_at"
        case durationSec = "duration_sec"
        case materialID = "material_id"
        case utterances
    }

    public init(
        sessionID: String,
        sceneType: String,
        status: String,
        startedAt: Date,
        durationSec: Int,
        materialID: String? = nil,
        utterances: [SessionUtterance] = []
    ) {
        self.sessionID = sessionID
        self.sceneType = sceneType
        self.status = status
        self.startedAt = startedAt
        self.durationSec = durationSec
        self.materialID = materialID
        self.utterances = utterances
    }
}

/// Decoding for the conversation list.
///
/// Exists because of `started_at`, and the reason is worth keeping:
///
/// The backend marshals `time.Time`, i.e. **RFC3339Nano — with the fractional
/// part variable**. Go drops trailing zeros, so the same field arrives as
/// `...T00:02:04.78+08:00` on one row and `...T00:02:04+08:00` on the next.
/// Neither of Swift's obvious answers survives that: a bare `JSONDecoder()`
/// expects a *number* (`.deferredToDate`), and Codable's `.iso8601` strategy
/// rejects fractional seconds outright. Both fail on real data, and both fail
/// equally on the rows that happen to have no fraction — so a fixture written
/// by hand with round timestamps would pass while production broke.
///
/// So the formatter tries both, and the test pins both.
public enum SessionHistoryJSON {
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)

            // Built per value rather than cached. `ISO8601DateFormatter` is not
            // `Sendable`, and this closure is `@Sendable` — so a `static let`
            // is rejected outright and a captured local is rejected too. The
            // alternatives are `nonisolated(unsafe)` (a thread-safety claim
            // nobody has verified here) or a lock (which this repository does
            // not use). A cursor page is at most 100 rows and never on a hot
            // path, so the honest trade is a formatter per date.
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]

            guard let date = withFraction.date(from: raw) ?? plain.date(from: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "expected an RFC3339 timestamp (fraction optional), got \(raw)"
                )
            }
            return date
        }
        return decoder
    }
}
