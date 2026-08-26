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

/// Review poll payload. `review` body stays opaque for I4; I6 consumes structure.
public struct ReviewPollResponse: Codable, Equatable, Sendable {
    public var sessionID: String
    public var status: ReviewPollStatus
    public var hasReviewPayload: Bool

    public init(sessionID: String, status: ReviewPollStatus, hasReviewPayload: Bool = false) {
        self.sessionID = sessionID
        self.status = status
        self.hasReviewPayload = hasReviewPayload
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case status
        case review
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        status = try container.decode(ReviewPollStatus.self, forKey: .status)
        if container.contains(.review) {
            hasReviewPayload = true
        } else {
            hasReviewPayload = false
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(status, forKey: .status)
        if hasReviewPayload {
            try container.encode(true, forKey: .review)
        }
    }
}
