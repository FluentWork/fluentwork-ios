import Foundation

// MARK: - API Models

/// Corresponds to OpenAPI `DailyRead` schema.
public struct DailyRead: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var title: String
  public var body: String
  public var audioURL: String?
  public var generator: String
  public var usedBlockIDs: [String]
  /// Untyped source_refs map; consumer only needs to know the field exists.
  public var sourceRefs: [String: JSONValue]
  public var readScore: Double?

  enum CodingKeys: String, CodingKey {
    case id
    case title
    case body
    case audioURL = "audio_url"
    case generator
    case usedBlockIDs = "used_block_ids"
    case sourceRefs = "source_refs"
    case readScore = "read_score"
  }

  public init(
    id: String,
    title: String,
    body: String,
    audioURL: String? = nil,
    generator: String,
    usedBlockIDs: [String] = [],
    sourceRefs: [String: JSONValue] = [:],
    readScore: Double? = nil
  ) {
    self.id = id
    self.title = title
    self.body = body
    self.audioURL = audioURL
    self.generator = generator
    self.usedBlockIDs = usedBlockIDs
    self.sourceRefs = sourceRefs
    self.readScore = readScore
  }
}

/// Corresponds to OpenAPI `DailyReadTodayResponse` schema.
public enum DailyReadStatus: String, Codable, Equatable, Sendable {
  case pending
  case ready
  case failed
}

public struct DailyReadTodayResponse: Codable, Equatable, Sendable {
  public var genDate: String
  public var status: DailyReadStatus
  public var dailyRead: DailyRead?

  enum CodingKeys: String, CodingKey {
    case genDate = "gen_date"
    case status
    case dailyRead = "daily_read"
  }

  public init(
    genDate: String,
    status: DailyReadStatus,
    dailyRead: DailyRead? = nil
  ) {
    self.genDate = genDate
    self.status = status
    self.dailyRead = dailyRead
  }
}

/// Corresponds to OpenAPI `FollowReadResponse` schema.
/// Note: `read_score` is nullable; V1.1 scoring is intentionally absent.
public struct EmptyRequest: Codable, Equatable, Sendable {}

public struct FollowReadResponse: Codable, Equatable, Sendable {
  public var dailyReadID: String
  public var recorded: Bool
  public var readScore: Double?
  public var generator: String

  enum CodingKeys: String, CodingKey {
    case dailyReadID = "daily_read_id"
    case recorded
    case readScore = "read_score"
    case generator
  }

  public init(
    dailyReadID: String,
    recorded: Bool,
    readScore: Double? = nil,
    generator: String
  ) {
    self.dailyReadID = dailyReadID
    self.recorded = recorded
    self.readScore = readScore
    self.generator = generator
  }
}
