import Foundation

/// OpenAPI `Error` body (`code`, `message`, `request_id`).
public struct APIErrorBody: Codable, Equatable, Sendable {
    public var code: String
    public var message: String
    public var requestID: String

    public init(code: String, message: String, requestID: String) {
        self.code = code
        self.message = message
        self.requestID = requestID
    }

    enum CodingKeys: String, CodingKey {
        case code
        case message
        case requestID = "request_id"
    }
}

public struct TokenResponse: Codable, Equatable, Sendable {
    public var userID: String
    public var isGuest: Bool
    public var status: String
    public var accessToken: String
    public var refreshToken: String
    public var tokenType: String
    public var expiresIn: Int

    public init(
        userID: String,
        isGuest: Bool,
        status: String,
        accessToken: String,
        refreshToken: String,
        tokenType: String = "Bearer",
        expiresIn: Int
    ) {
        self.userID = userID
        self.isGuest = isGuest
        self.status = status
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.expiresIn = expiresIn
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case isGuest = "is_guest"
        case status
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }
}

public struct MergeResponse: Codable, Equatable, Sendable {
    public var userID: String
    public var isGuest: Bool
    public var mergedFromUserID: String?
    public var alreadyMerged: Bool

    public init(
        userID: String,
        isGuest: Bool,
        mergedFromUserID: String? = nil,
        alreadyMerged: Bool
    ) {
        self.userID = userID
        self.isGuest = isGuest
        self.mergedFromUserID = mergedFromUserID
        self.alreadyMerged = alreadyMerged
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case isGuest = "is_guest"
        case mergedFromUserID = "merged_from_user_id"
        case alreadyMerged = "already_merged"
    }
}

public struct CreateSessionResponse: Codable, Equatable, Sendable {
    public var sessionID: String
    public var wssURL: String
    public var ticket: String
    public var ticketExpiresIn: Int
    public var ticketExpiresAt: String
    public var sceneType: String
    public var status: String

    public init(
        sessionID: String,
        wssURL: String,
        ticket: String,
        ticketExpiresIn: Int,
        ticketExpiresAt: String,
        sceneType: String,
        status: String
    ) {
        self.sessionID = sessionID
        self.wssURL = wssURL
        self.ticket = ticket
        self.ticketExpiresIn = ticketExpiresIn
        self.ticketExpiresAt = ticketExpiresAt
        self.sceneType = sceneType
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case wssURL = "wss_url"
        case ticket
        case ticketExpiresIn = "ticket_expires_in"
        case ticketExpiresAt = "ticket_expires_at"
        case sceneType = "scene_type"
        case status
    }
}

public enum ReviewPollStatus: String, Codable, Equatable, Sendable {
    case pending
    case ready
    case failed
}

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSONValue payload"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

public struct TranscriptTurn: Codable, Equatable, Sendable, Identifiable {
    public var seq: Int
    public var speaker: String
    public var text: String

    public var id: String { "\(seq)-\(speaker)" }
}

public struct GoalAchievement: Codable, Equatable, Sendable {
    public var met: Bool
    public var note: String
}

public struct ReviewOverview: Codable, Equatable, Sendable {
    public var goalAchievement: GoalAchievement
    public var issueCount: Int
    public var suggestionCount: Int
    public var comparisonCount: Int

    enum CodingKeys: String, CodingKey {
        case goalAchievement = "goal_achievement"
        case issueCount = "issue_count"
        case suggestionCount = "suggestion_count"
        case comparisonCount = "comparison_count"
    }
}

public struct ReviewIssue: Codable, Equatable, Sendable, Identifiable {
    public var type: String
    public var originalQuote: String
    public var hint: String

    public var id: String { "\(type)-\(originalQuote)" }

    enum CodingKeys: String, CodingKey {
        case type
        case originalQuote = "original_quote"
        case hint
    }
}

public struct SuggestionItem: Codable, Equatable, Sendable, Identifiable {
    public var text: String

    public var id: String { text }
}

public struct ComparisonRow: Codable, Equatable, Sendable, Identifiable {
    public var user: String
    public var better: String

    public var id: String { "\(user)-\(better)" }
}

public struct RefineCard: Codable, Equatable, Sendable, Identifiable {
    public var intentZH: String
    public var expressionEN: String
    public var anchorUserSaid: String
    public var sceneTag: String
    public var functionTag: String

    public var id: String { "\(expressionEN)-\(anchorUserSaid)" }

    enum CodingKeys: String, CodingKey {
        case intentZH = "intent_zh"
        case expressionEN = "expression_en"
        case anchorUserSaid = "anchor_user_said"
        case sceneTag = "scene_tag"
        case functionTag = "function_tag"
    }
}

public struct ReviewDoc: Codable, Equatable, Sendable {
    public var goalAchievement: GoalAchievement
    public var issues: [ReviewIssue]
    public var suggestions: [SuggestionItem]
    public var comparisons: [ComparisonRow]

    enum CodingKeys: String, CodingKey {
        case goalAchievement = "goal_achievement"
        case issues
        case suggestions
        case comparisons
    }
}

public struct RefineDoc: Codable, Equatable, Sendable {
    public var blocks: [RefineCard]
}

public struct ReviewEvaluationLayer: Codable, Equatable, Sendable, Identifiable {
    public var layer: String
    public var title: String
    public var content: JSONValue

    public var id: String { layer }
}

public struct ReviewReadyPayload: Codable, Equatable, Sendable {
    public var generator: String
    public var status: String
    public var durationSec: Int?
    public var transcript: [TranscriptTurn]
    public var overview: ReviewOverview
    public var evaluation: [ReviewEvaluationLayer]
    public var dualColumn: [ComparisonRow]
    public var refineCards: [RefineCard]
    public var review: ReviewDoc
    public var refine: RefineDoc

    enum CodingKeys: String, CodingKey {
        case generator
        case status
        case durationSec = "duration_sec"
        case transcript
        case overview
        case evaluation
        case dualColumn = "dual_column"
        case refineCards = "refine_cards"
        case review
        case refine
    }
}

public struct ReviewPollResponse: Codable, Equatable, Sendable {
    public var sessionID: String
    public var status: ReviewPollStatus
    public var review: ReviewReadyPayload?

    public init(sessionID: String, status: ReviewPollStatus, review: ReviewReadyPayload? = nil) {
        self.sessionID = sessionID
        self.status = status
        self.review = review
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case status
        case review
    }
}

public struct PostMessageRequest: Codable, Equatable, Sendable {
    public var text: String
    /// Must be `"text"` for degrade path; empty/other → backend CONFLICT while voice preferred.
    public var channel: String

    public init(text: String, channel: String = "text") {
        self.text = text
        self.channel = channel
    }
}

public struct PostMessageResponse: Codable, Equatable, Sendable {
    public var sessionID: String
    public var reply: String
    public var channel: String
    public var generator: String

    public init(sessionID: String, reply: String, channel: String, generator: String) {
        self.sessionID = sessionID
        self.reply = reply
        self.channel = channel
        self.generator = generator
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case reply
        case channel
        case generator
    }
}

public struct PhraseBlock: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var intentZH: String
    public var expressionEN: String
    public var anchorUserSaid: String
    public var sceneTag: String
    public var functionTag: String
    public var state: String
    public var successStreak: Int
    public var nextDueAt: String
    public var easeFactor: Double
    public var realUseCount: Int
    public var isFavorite: Bool
    public var pinnedAt: String?
    public var sourceSessionID: String?
    public var createdAt: String
    public var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case intentZH = "intent_zh"
        case expressionEN = "expression_en"
        case anchorUserSaid = "anchor_user_said"
        case sceneTag = "scene_tag"
        case functionTag = "function_tag"
        case state
        case successStreak = "success_streak"
        case nextDueAt = "next_due_at"
        case easeFactor = "ease_factor"
        case realUseCount = "real_use_count"
        case isFavorite = "is_favorite"
        case pinnedAt = "pinned_at"
        case sourceSessionID = "source_session_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct ListPhraseBlocksResponse: Codable, Equatable, Sendable {
    public var items: [PhraseBlock]
    public var nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
    }
}

public struct CorpusBatchAcceptBlockRequest: Codable, Equatable, Sendable {
    public var intentZH: String
    public var expressionEN: String
    public var anchorUserSaid: String
    public var sceneTag: String
    public var functionTag: String

    public init(
        intentZH: String,
        expressionEN: String,
        anchorUserSaid: String,
        sceneTag: String,
        functionTag: String
    ) {
        self.intentZH = intentZH
        self.expressionEN = expressionEN
        self.anchorUserSaid = anchorUserSaid
        self.sceneTag = sceneTag
        self.functionTag = functionTag
    }

    enum CodingKeys: String, CodingKey {
        case intentZH = "intent_zh"
        case expressionEN = "expression_en"
        case anchorUserSaid = "anchor_user_said"
        case sceneTag = "scene_tag"
        case functionTag = "function_tag"
    }
}

public struct CorpusBatchAcceptRequest: Codable, Equatable, Sendable {
    public var sourceSessionID: String
    public var blocks: [CorpusBatchAcceptBlockRequest]

    public init(sourceSessionID: String, blocks: [CorpusBatchAcceptBlockRequest]) {
        self.sourceSessionID = sourceSessionID
        self.blocks = blocks
    }

    enum CodingKeys: String, CodingKey {
        case sourceSessionID = "source_session_id"
        case blocks
    }
}

public struct BatchAcceptBlocksResponse: Codable, Equatable, Sendable {
    public var acceptedCount: Int
    public var items: [PhraseBlock]

    enum CodingKeys: String, CodingKey {
        case acceptedCount = "accepted_count"
        case items
    }
}

public struct UpdateCorpusBlockRequest: Codable, Equatable, Sendable {
    public var intentZH: String
    public var expressionEN: String
    public var anchorUserSaid: String
    public var sceneTag: String
    public var functionTag: String

    public init(
        intentZH: String,
        expressionEN: String,
        anchorUserSaid: String,
        sceneTag: String,
        functionTag: String
    ) {
        self.intentZH = intentZH
        self.expressionEN = expressionEN
        self.anchorUserSaid = anchorUserSaid
        self.sceneTag = sceneTag
        self.functionTag = functionTag
    }

    enum CodingKeys: String, CodingKey {
        case intentZH = "intent_zh"
        case expressionEN = "expression_en"
        case anchorUserSaid = "anchor_user_said"
        case sceneTag = "scene_tag"
        case functionTag = "function_tag"
    }
}

public struct FavoriteCorpusBlockRequest: Codable, Equatable, Sendable {
    public var isFavorite: Bool
    public var pinned: Bool

    public init(isFavorite: Bool, pinned: Bool) {
        self.isFavorite = isFavorite
        self.pinned = pinned
    }

    enum CodingKeys: String, CodingKey {
        case isFavorite = "is_favorite"
        case pinned
    }
}

public struct DeleteCorpusBlockResponse: Codable, Equatable, Sendable {
    public var deleted: Bool
}
