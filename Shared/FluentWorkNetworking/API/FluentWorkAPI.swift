import Foundation
import Moya

/// REST targets aligned to `fluentwork-backend/api/openapi-v1.yaml`.
public enum FluentWorkAPI: FluentWorkTargetType {
  case issueGuest(deviceID: String)
  case mergeGuestAccount(deviceID: String, accessToken: String)
  case refreshToken(accessToken: String)
  case createSession(
    accessToken: String,
    materialID: String? = nil,
    sceneType: String? = nil
  )
  case getSessionReview(sessionID: String, accessToken: String)
  case sendSessionMessage(
    sessionID: String, accessToken: String, text: String, channel: String = "text")
  case listCorpusBlocks(
    accessToken: String,
    scene: String? = nil,
    function: String? = nil,
    keyword: String? = nil,
    cursor: String? = nil,
    updatedAfter: String? = nil,
    limit: Int? = nil,
    favoriteOnly: Bool = false
  )
  case batchAcceptCorpusBlocks(
    accessToken: String,
    sourceSessionID: String,
    blocks: [CorpusBatchAcceptBlockRequest]
  )
  case updateCorpusBlock(
    accessToken: String,
    blockID: String,
    request: UpdateCorpusBlockRequest
  )
  case deleteCorpusBlock(accessToken: String, blockID: String)
  case favoriteCorpusBlock(
    accessToken: String,
    blockID: String,
    isFavorite: Bool,
    pinned: Bool
  )
  case getDailyReadToday(accessToken: String)
  case postDailyReadFollowRead(accessToken: String, dailyReadID: String, audioURL: String?)

  public var baseURL: URL {
    // Overridden by SessionAPIClient via AbsoluteURL target wrapper — unused.
    URL(string: "http://127.0.0.1")!
  }

  public var path: String {
    switch self {
    case .issueGuest:
      return "/auth/guest"
    case .mergeGuestAccount:
      return "/account/merge"
    case .refreshToken:
      return "/auth/refresh"
    case .createSession:
      return "/sessions"
    case .getSessionReview(let sessionID, _):
      return "/sessions/\(sessionID)/review"
    case .sendSessionMessage(let sessionID, _, _, _):
      return "/sessions/\(sessionID)/messages"
    case .listCorpusBlocks:
      return "/corpus/blocks"
    case .batchAcceptCorpusBlocks:
      return "/corpus/blocks/batch-accept"
    case .updateCorpusBlock(_, let blockID, _),
      .deleteCorpusBlock(_, let blockID):
      return "/corpus/blocks/\(blockID)"
    case .favoriteCorpusBlock(_, let blockID, _, _):
      return "/corpus/blocks/\(blockID)/favorite"
    case .getDailyReadToday:
      return "/daily-reads/today"
    case .postDailyReadFollowRead(_, let dailyReadID, _):
      return "/daily-reads/\(dailyReadID)/follow-read"
    }
  }

  public var method: Moya.Method {
    switch self {
    case .getDailyReadToday, .getSessionReview, .listCorpusBlocks:
      return .get
    case .deleteCorpusBlock:
      return .delete
    case .updateCorpusBlock:
      return .put
    case .issueGuest,
      .mergeGuestAccount,
      .refreshToken,
      .createSession,
      .sendSessionMessage,
      .batchAcceptCorpusBlocks,
      .favoriteCorpusBlock,
      .postDailyReadFollowRead:
      return .post
    }
  }

  public var task: Task {
    switch self {
    case .issueGuest(let deviceID):
      return .requestParameters(
        parameters: ["device_id": deviceID],
        encoding: JSONEncoding.default
      )
    case .mergeGuestAccount(let deviceID, _):
      return .requestParameters(
        parameters: ["device_id": deviceID],
        encoding: JSONEncoding.default
      )
    case .refreshToken:
      return .requestPlain
    case .createSession(_, let materialID, let sceneType):
      var parameters: [String: Any] = [:]
      if let materialID {
        parameters["material_id"] = materialID
      }
      if let sceneType {
        parameters["scene_type"] = sceneType
      }
      if parameters.isEmpty {
        return .requestPlain
      }
      return .requestParameters(parameters: parameters, encoding: JSONEncoding.default)
    case .getSessionReview:
      return .requestPlain
    case .sendSessionMessage(_, _, let text, let channel):
      return .requestParameters(
        parameters: ["text": text, "channel": channel],
        encoding: JSONEncoding.default
      )
    case .listCorpusBlocks(
      _, let scene, let function, let keyword, let cursor, let updatedAfter, let limit,
      let favoriteOnly):
      var parameters: [String: Any] = [:]
      if let scene, !scene.isEmpty {
        parameters["scene"] = scene
      }
      if let function, !function.isEmpty {
        parameters["func"] = function
      }
      if let keyword, !keyword.isEmpty {
        parameters["kw"] = keyword
      }
      if let cursor, !cursor.isEmpty {
        parameters["cursor"] = cursor
      }
      if let updatedAfter, !updatedAfter.isEmpty {
        parameters["updated_after"] = updatedAfter
      }
      if let limit {
        parameters["limit"] = limit
      }
      if favoriteOnly {
        parameters["favorite_only"] = true
      }
      if parameters.isEmpty {
        return .requestPlain
      }
      return .requestParameters(parameters: parameters, encoding: URLEncoding.queryString)
    case .batchAcceptCorpusBlocks(_, let sourceSessionID, let blocks):
      return .requestJSONEncodable(
        CorpusBatchAcceptRequest(
          sourceSessionID: sourceSessionID,
          blocks: blocks
        )
      )
    case .updateCorpusBlock(_, _, let request):
      return .requestJSONEncodable(request)
    case .deleteCorpusBlock:
      return .requestPlain
    case .favoriteCorpusBlock(_, _, let isFavorite, let pinned):
      return .requestJSONEncodable(
        FavoriteCorpusBlockRequest(
          isFavorite: isFavorite,
          pinned: pinned
        )
      )
    case .getDailyReadToday:
      return .requestPlain
    case .postDailyReadFollowRead(_, _, let audioURL):
      if let audioURL {
        return .requestJSONEncodable(["audio_url": audioURL])
      }
      return .requestJSONEncodable(EmptyRequest())
    }
  }

  public var headers: [String: String]? {
    var headers = ["Content-Type": "application/json", "Accept": "application/json"]
    if let token = accessToken {
      headers["Authorization"] = "Bearer \(token)"
    }
    return headers
  }

  private var accessToken: String? {
    switch self {
    case .issueGuest:
      return nil
    case .mergeGuestAccount(_, let token),
      .refreshToken(let token),
      .createSession(let token, _, _),
      .getSessionReview(_, let token),
      .sendSessionMessage(_, let token, _, _),
      .listCorpusBlocks(let token, _, _, _, _, _, _, _),
      .batchAcceptCorpusBlocks(let token, _, _),
      .updateCorpusBlock(let token, _, _),
      .deleteCorpusBlock(let token, _),
      .favoriteCorpusBlock(let token, _, _, _),
      .getDailyReadToday(let token),
      .postDailyReadFollowRead(let token, _, _):
      return token
    }
  }
}

/// Binds a relative `FluentWorkAPI` path onto an environment base URL (`…/api/v1`).
public struct AbsoluteFluentWorkTarget: FluentWorkTargetType {
  public let baseURL: URL
  public let api: FluentWorkAPI

  public init(baseURL: URL, api: FluentWorkAPI) {
    self.baseURL = baseURL
    self.api = api
  }

  public var path: String { api.path }
  public var method: Moya.Method { api.method }
  public var task: Task { api.task }
  public var headers: [String: String]? { api.headers }
}
