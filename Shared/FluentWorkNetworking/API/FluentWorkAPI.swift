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
    /// Wiring point until backend B7 / OpenAPI documents `POST /sessions/{id}/messages`.
    case sendSessionMessage(sessionID: String, accessToken: String, text: String)

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
        case let .sendSessionMessage(sessionID, _, _):
            return "/sessions/\(sessionID)/messages"
        }
    }

    public var method: Moya.Method {
        switch self {
        case .getSessionReview:
            return .get
        case .issueGuest, .mergeGuestAccount, .createSession, .sendSessionMessage:
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
        case let .sendSessionMessage(_, _, text):
            return .requestParameters(
                parameters: ["text": text],
                encoding: JSONEncoding.default
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
             let .sendSessionMessage(_, token, _):
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
