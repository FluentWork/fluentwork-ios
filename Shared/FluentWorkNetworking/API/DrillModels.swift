import Foundation
import Moya

public enum DrillBlockState: String, Codable, Equatable, Sendable {
    case new
    case training
    case automated
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DrillBlockState(rawValue: raw) ?? .unknown
    }
}

public struct DrillCard: Codable, Equatable, Sendable, Identifiable {
    public let blockID: String
    public let intentZH: String
    public let expressionEN: String
    public let state: DrillBlockState

    public var id: String { blockID }

    enum CodingKeys: String, CodingKey {
        case blockID = "block_id"
        case intentZH = "intent_zh"
        case expressionEN = "expression_en"
        case state
    }

    public init(
        blockID: String,
        intentZH: String,
        expressionEN: String,
        state: DrillBlockState = .unknown
    ) {
        self.blockID = blockID
        self.intentZH = intentZH
        self.expressionEN = expressionEN
        self.state = state
    }
}

public struct DrillRound: Codable, Equatable, Sendable {
    public let size: Int
    public let cards: [DrillCard]

    public init(size: Int, cards: [DrillCard]) {
        self.size = size
        self.cards = cards
    }
}

public struct DrillVerdict: Codable, Equatable, Sendable {
    public let pass: Bool
    public let judgeReason: String
    public let judged: Bool
    public let retryable: Bool
    public let successStreak: Int
    public let state: DrillBlockState
    public let nextDueAt: Date
    public let recorded: Bool
    public let recordID: Int64
    public let promoted: Bool
    public let asrText: String

    public var canAppeal: Bool { judged && recorded && recordID != 0 }
    public var needsConfirmation: Bool { !judged }

    enum CodingKeys: String, CodingKey {
        case pass
        case judgeReason = "judge_reason"
        case judged
        case retryable
        case successStreak = "success_streak"
        case state
        case nextDueAt = "next_due_at"
        case recorded
        case recordID = "record_id"
        case promoted
        case asrText = "asr_text"
    }

    public init(
        pass: Bool,
        judgeReason: String,
        judged: Bool,
        retryable: Bool = false,
        successStreak: Int,
        state: DrillBlockState,
        nextDueAt: Date,
        recorded: Bool,
        recordID: Int64 = 0,
        promoted: Bool = false,
        asrText: String = ""
    ) {
        self.pass = pass
        self.judgeReason = judgeReason
        self.judged = judged
        self.retryable = retryable
        self.successStreak = successStreak
        self.state = state
        self.nextDueAt = nextDueAt
        self.recorded = recorded
        self.recordID = recordID
        self.promoted = promoted
        self.asrText = asrText
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pass = try container.decode(Bool.self, forKey: .pass)
        judgeReason = try container.decode(String.self, forKey: .judgeReason)
        judged = try container.decode(Bool.self, forKey: .judged)
        retryable = try container.decodeIfPresent(Bool.self, forKey: .retryable) ?? false
        successStreak = try container.decode(Int.self, forKey: .successStreak)
        state = try container.decode(DrillBlockState.self, forKey: .state)
        nextDueAt = try container.decode(Date.self, forKey: .nextDueAt)
        recorded = try container.decode(Bool.self, forKey: .recorded)
        recordID = try container.decodeIfPresent(Int64.self, forKey: .recordID) ?? 0
        promoted = try container.decodeIfPresent(Bool.self, forKey: .promoted) ?? false
        asrText = try container.decodeIfPresent(String.self, forKey: .asrText) ?? ""
    }
}

public struct DrillAppealOutcome: Codable, Equatable, Sendable {
    public let recordID: Int64
    public let blockID: String
    public let restored: Bool
    public let alreadyAppealed: Bool
    public let state: DrillBlockState
    public let successStreak: Int
    public let nextDueAt: Date
    public let note: String?

    enum CodingKeys: String, CodingKey {
        case recordID = "record_id"
        case blockID = "block_id"
        case restored
        case alreadyAppealed = "already_appealed"
        case state
        case successStreak = "success_streak"
        case nextDueAt = "next_due_at"
        case note
    }

    public init(
        recordID: Int64,
        blockID: String,
        restored: Bool,
        alreadyAppealed: Bool,
        state: DrillBlockState,
        successStreak: Int,
        nextDueAt: Date,
        note: String? = nil
    ) {
        self.recordID = recordID
        self.blockID = blockID
        self.restored = restored
        self.alreadyAppealed = alreadyAppealed
        self.state = state
        self.successStreak = successStreak
        self.nextDueAt = nextDueAt
        self.note = note
    }
}

public protocol DrillClientProtocol: Sendable {
    func dueRound(accessToken: String, size: Int) async throws -> DrillRound
    func judge(
        accessToken: String,
        blockID: String,
        asrText: String,
        responseMS: Int,
        sessionID: String?
    ) async throws -> DrillVerdict
    func appeal(accessToken: String, recordID: Int64) async throws -> DrillAppealOutcome
}

public final class DrillAPIClient: DrillClientProtocol, Sendable {
    private let network: NetworkClientProtocol
    private let baseURL: URL

    public init(network: NetworkClientProtocol, baseURL: URL) {
        self.network = network
        self.baseURL = baseURL
    }

    public func dueRound(accessToken: String, size: Int) async throws -> DrillRound {
        try await decode(
            DrillRound.self,
            .drillRound(accessToken: accessToken, size: size)
        )
    }

    public func judge(
        accessToken: String,
        blockID: String,
        asrText: String,
        responseMS: Int,
        sessionID: String?
    ) async throws -> DrillVerdict {
        try await decode(
            DrillVerdict.self,
            .drillJudge(
                accessToken: accessToken,
                blockID: blockID,
                asrText: asrText,
                responseMS: responseMS,
                sessionID: sessionID
            )
        )
    }

    public func appeal(accessToken: String, recordID: Int64) async throws -> DrillAppealOutcome {
        try await decode(
            DrillAppealOutcome.self,
            .drillAppeal(accessToken: accessToken, recordID: recordID)
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, _ api: FluentWorkAPI) async throws -> T {
        let data = try await network.requestData(
            for: AbsoluteFluentWorkTarget(baseURL: baseURL, api: api)
        )
        do {
            return try SessionHistoryJSON.makeDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(description: error.localizedDescription)
        }
    }
}
