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

/// `POST /api/v1/materials` 的回包（HTTP 202）。
///
/// `refineStatus` 说的是**提炼**的进度，不是素材本身能不能用：会话只要 `materialID`，
/// 提炼发生在会话之前/并行都行（`internal/materials/model.go`：`queued` → `processing` → `ready`）。
public struct CreateMaterialResponse: Codable, Equatable, Sendable {
    public var materialID: String
    public var refineStatus: String

    public init(materialID: String, refineStatus: String) {
        self.materialID = materialID
        self.refineStatus = refineStatus
    }

    enum CodingKeys: String, CodingKey {
        case materialID = "material_id"
        case refineStatus = "refine_status"
    }
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

/// `DELETE /account/data` 的回执（A4）。
///
/// `cascaded` 是**删完之后**服务端数出来的级联计数（表名 → 行数）。
/// 它是这一屏唯一能拿到的「删了多少」的真相 —— 见 `AccountDataFeature` 里
/// 「确认之前拿不到 N」那段说明。
public struct DeleteAccountDataResponse: Codable, Equatable, Sendable {
    public var cascaded: [String: Int]
    /// 备份彻底清除的时间点。**不显示**，但它在契约里，且它是「删除」这个承诺的一部分
    /// （软删 + 备份保留期），所以照样解码下来。
    public var backupPurgeAt: String
    /// 第二次调用时为 true（幂等）。屏幕上据此说「数据已经不在了」，而不是报错。
    public var alreadyDeleted: Bool

    enum CodingKeys: String, CodingKey {
        case cascaded
        case backupPurgeAt = "backup_purge_at"
        case alreadyDeleted = "already_deleted"
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
    public var deletedAt: String?
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
        case deletedAt = "deleted_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: String,
        intentZH: String,
        expressionEN: String,
        anchorUserSaid: String,
        sceneTag: String,
        functionTag: String,
        state: String,
        successStreak: Int,
        nextDueAt: String,
        easeFactor: Double,
        realUseCount: Int,
        isFavorite: Bool,
        pinnedAt: String?,
        sourceSessionID: String?,
        deletedAt: String? = nil,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.intentZH = intentZH
        self.expressionEN = expressionEN
        self.anchorUserSaid = anchorUserSaid
        self.sceneTag = sceneTag
        self.functionTag = functionTag
        self.state = state
        self.successStreak = successStreak
        self.nextDueAt = nextDueAt
        self.easeFactor = easeFactor
        self.realUseCount = realUseCount
        self.isFavorite = isFavorite
        self.pinnedAt = pinnedAt
        self.sourceSessionID = sourceSessionID
        self.deletedAt = deletedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ListPhraseBlocksResponse: Codable, Equatable, Sendable {
    public var items: [PhraseBlock]
    public var nextCursor: String?
    public var cursorReset: Bool

    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
        case cursorReset = "cursor_reset"
    }

    public init(items: [PhraseBlock], nextCursor: String?, cursorReset: Bool = false) {
        self.items = items
        self.nextCursor = nextCursor
        self.cursorReset = cursorReset
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
