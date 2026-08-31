import Foundation
import Moya

/// First-wave REST targets aligned to `fluentwork-backend/api/openapi-v1.yaml`.
public enum FluentWorkAPI: FluentWorkTargetType {
    case issueGuest(deviceID: String)
    case mergeGuestAccount(deviceID: String, accessToken: String)
    case createSession(
        accessToken: String,
        materialID: String? = nil,
        sceneType: String? = nil
    )
    case getSessionReview(sessionID: String, accessToken: String)
    case sendSessionMessage(sessionID: String, accessToken: String, text: String, channel: String = "text")
    case listCorpusBlocks(
        accessToken: String,
        scene: String? = nil,
        function: String? = nil,
        keyword: String? = nil,
        cursor: String? = nil,
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
        case .createSession:
            return "/sessions"
        case let .getSessionReview(sessionID, _):
            return "/sessions/\(sessionID)/review"
        case let .sendSessionMessage(sessionID, _, _, _):
            return "/sessions/\(sessionID)/messages"
        case .listCorpusBlocks:
            return "/corpus/blocks"
        case .batchAcceptCorpusBlocks:
            return "/corpus/blocks/batch-accept"
        case let .updateCorpusBlock(_, blockID, _),
             let .deleteCorpusBlock(_, blockID):
            return "/corpus/blocks/\(blockID)"
        case let .favoriteCorpusBlock(_, blockID, _, _):
            return "/corpus/blocks/\(blockID)/favorite"
        }
    }

    public var method: Moya.Method {
        switch self {
        case .getSessionReview, .listCorpusBlocks:
            return .get
        case .deleteCorpusBlock:
            return .delete
        case .updateCorpusBlock:
            return .put
        case .issueGuest,
             .mergeGuestAccount,
             .createSession,
             .sendSessionMessage,
             .batchAcceptCorpusBlocks,
             .favoriteCorpusBlock:
            return .post
        }
    }

    public var task: Task {
        switch self {
        case let .issueGuest(deviceID):
            return .requestParameters(
                parameters: ["device_id": deviceID],
                encoding: JSONEncoding.default
            )
        case let .mergeGuestAccount(deviceID, _):
            return .requestParameters(
                parameters: ["device_id": deviceID],
                encoding: JSONEncoding.default
            )
        case let .createSession(_, materialID, sceneType):
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
        case let .sendSessionMessage(_, _, text, channel):
            return .requestParameters(
                parameters: ["text": text, "channel": channel],
                encoding: JSONEncoding.default
            )
        case let .listCorpusBlocks(_, scene, function, keyword, cursor, limit, favoriteOnly):
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
        case let .batchAcceptCorpusBlocks(_, sourceSessionID, blocks):
            return .requestJSONEncodable(
                CorpusBatchAcceptRequest(
                    sourceSessionID: sourceSessionID,
                    blocks: blocks
                )
            )
        case let .updateCorpusBlock(_, _, request):
            return .requestJSONEncodable(request)
        case .deleteCorpusBlock:
            return .requestPlain
        case let .favoriteCorpusBlock(_, _, isFavorite, pinned):
            return .requestJSONEncodable(
                FavoriteCorpusBlockRequest(
                    isFavorite: isFavorite,
                    pinned: pinned
                )
            )
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
        case let .mergeGuestAccount(_, token),
             let .createSession(token, _, _),
             let .getSessionReview(_, token),
             let .sendSessionMessage(_, token, _, _),
             let .listCorpusBlocks(token, _, _, _, _, _, _),
             let .batchAcceptCorpusBlocks(token, _, _),
             let .updateCorpusBlock(token, _, _),
             let .deleteCorpusBlock(token, _),
             let .favoriteCorpusBlock(token, _, _, _):
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
