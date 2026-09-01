import Foundation

public enum AppEnvironmentKind: String, Sendable, Equatable {
    case development
    case local
    case production
}

public struct AppEnvironment: Equatable, Sendable {
    public var kind: AppEnvironmentKind
    public var apiBaseURL: URL
    public var wssBaseURL: URL
    public var minimumLogLevelIsDebug: Bool

    public init(
        kind: AppEnvironmentKind,
        apiBaseURL: URL,
        wssBaseURL: URL,
        minimumLogLevelIsDebug: Bool
    ) {
        self.kind = kind
        self.apiBaseURL = apiBaseURL
        self.wssBaseURL = wssBaseURL
        self.minimumLogLevelIsDebug = minimumLogLevelIsDebug
    }

    public static let development = AppEnvironment(
        kind: .development,
        apiBaseURL: URL(string: "https://dev-api.fluentwork.local/api/v1")!,
        wssBaseURL: URL(string: "wss://dev-api.fluentwork.local")!,
        minimumLogLevelIsDebug: true
    )

    public static let local = AppEnvironment(
        kind: .local,
        apiBaseURL: URL(string: "http://192.168.2.15:8080/api/v1")!,
        wssBaseURL: URL(string: "ws://192.168.2.15:8081/v1/voice")!,
        minimumLogLevelIsDebug: true
    )

    #if DEBUG
    public static let current: AppEnvironment = .local
    #else
    public static let current: AppEnvironment = AppEnvironment(
        kind: .production,
        apiBaseURL: URL(string: "https://api.fluentwork.app/api/v1")!,
        wssBaseURL: URL(string: "wss://api.fluentwork.app")!,
        minimumLogLevelIsDebug: false
    )
    #endif
}
