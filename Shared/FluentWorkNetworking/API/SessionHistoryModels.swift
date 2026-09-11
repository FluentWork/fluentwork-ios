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
