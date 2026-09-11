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

    /// Local development environment
    /// - Default: 127.0.0.1 (simulator)
    /// - Override with custom IP: `AppEnvironment.local(host: "192.168.1.100")`
    public static let local = AppEnvironment(
        kind: .local,
        apiBaseURL: URL(string: "http://192.168.2.15:8080/api/v1")!,
        wssBaseURL: URL(string: "ws://192.168.2.15:8081/v1/voice")!,
        minimumLogLevelIsDebug: true
    )

    /// Create a local environment with custom host IP
    /// - Parameter host: The local machine's IP address (e.g., "192.168.2.15")
    /// - Returns: AppEnvironment configured for the specified host
    public static func local(host: String) -> AppEnvironment {
        AppEnvironment(
            kind: .local,
            apiBaseURL: URL(string: "http://\(host):8080/api/v1")!,
            wssBaseURL: URL(string: "ws://\(host):8081/v1/voice")!,
            minimumLogLevelIsDebug: true
        )
    }

    /// Test-only local environment using TEST_LOCAL_HOST or 127.0.0.1 fallback.
    /// Does not affect production `.local` configuration.
    #if DEBUG
    public static let testLocal = AppEnvironment(
        kind: .local,
        apiBaseURL: URL(string: "http://\(testLocalHost ?? "127.0.0.1"):8080/api/v1")!,
        wssBaseURL: URL(string: "ws://\(testLocalHost ?? "127.0.0.1"):8081/v1/voice")!,
        minimumLogLevelIsDebug: true
    )
    #endif

    #if DEBUG
    // MARK: - Test Override
    // Set TEST_LOCAL_HOST environment variable to override .local host for unit tests.
    // This keeps test expectations independent of actual development machine IP.
    private static let testLocalHost: String? = {
        ProcessInfo.processInfo.environment["TEST_LOCAL_HOST"]
    }()

    // MARK: - Current Environment Override
    // Three ways to configure for physical device testing:
    //
    // 1. Environment Variable (Recommended):
    //    In Xcode: Product → Scheme → Edit Scheme → Run → Arguments → Environment Variables
    //    Add: LOCAL_HOST = "192.168.x.x"
    //
    // 2. Direct Code Override:
    //    Change this to: .local(host: "192.168.x.x")
    //
    // 3. Runtime Detection:
    //    Keep as-is, set LOCAL_HOST in scheme or environment
    public static let current: AppEnvironment = {
        // Check for LOCAL_HOST environment variable first
        if let host = ProcessInfo.processInfo.environment["LOCAL_HOST"], !host.isEmpty {
            return .local(host: host)
        }
        // Fall back to localhost (works for simulator)
        return .local
    }()
    #else
    public static let current: AppEnvironment = AppEnvironment(
        kind: .production,
        apiBaseURL: URL(string: "https://api.fluentwork.app/api/v1")!,
        wssBaseURL: URL(string: "wss://api.fluentwork.app")!,
        minimumLogLevelIsDebug: false
    )
    #endif
}
