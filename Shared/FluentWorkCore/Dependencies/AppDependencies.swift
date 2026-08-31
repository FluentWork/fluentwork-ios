import FactoryKit
import FluentWorkDiagnostics
import FluentWorkFeatureFlags
import FluentWorkNetworking
import FluentWorkPluginSupport
import Foundation
import TGFeatureFlag

public protocol BootstrapClientProtocol: Sendable {
    func loadBootstrap() async throws -> BootstrapSnapshot
}

public protocol AudioEngineProtocol: Sendable {
    func startCapture() async throws
    func stopCapture() async
    func interruptNow() async
}

public protocol SpeechSessionClientProtocol: Sendable {
    func startSession() async throws
    func submitTranscript(_ text: String) async
    func pollReview(sessionID: String) async throws -> ReviewPollResponse
    func sendDegradedTextMessage(_ text: String) async throws -> PostMessageResponse
    func endSession() async
}

public protocol NetworkPluginFactoryProtocol: Sendable {
    func makeNetworkClient() -> NetworkClientProtocol
}

public struct StaticBootstrapClient: BootstrapClientProtocol {
    public let snapshot: BootstrapSnapshot

    public init(snapshot: BootstrapSnapshot = .preview) {
        self.snapshot = snapshot
    }

    public func loadBootstrap() async throws -> BootstrapSnapshot {
        snapshot
    }
}

/// Loads flags via TGFeatureFlag `FeatureFlagResolver`, then maps into Redux domain snapshot.
public struct ResolverBackedBootstrapClient: BootstrapClientProtocol {
    public let resolver: FeatureFlagResolver
    public let preferredSurface: WorkspaceSurface

    public init(
        resolver: FeatureFlagResolver = FeatureFlagResolverFactory.makeFirstWaveResolver(),
        preferredSurface: WorkspaceSurface = .speakingRoom
    ) {
        self.resolver = resolver
        self.preferredSurface = preferredSurface
    }

    public func loadBootstrap() async throws -> BootstrapSnapshot {
        _ = await resolver.refresh()
        let remote = resolver.snapshot(for: AppFeatureFlag.allCases)
        return BootstrapSnapshot(
            featureFlags: FeatureFlagSnapshotMapper.map(remote),
            preferredSurface: preferredSurface
        )
    }
}

public struct DefaultNetworkPluginFactory: NetworkPluginFactoryProtocol {
    public init() {}

    public func makeNetworkClient() -> NetworkClientProtocol {
        MoyaNetworkClient()
    }
}

public final class PlaceholderAudioEngine: AudioEngineProtocol, Sendable {
    public init() {}

    public func startCapture() async throws {}

    public func stopCapture() async {}

    public func interruptNow() async {}
}

public final class PlaceholderSpeechSessionClient: SpeechSessionClientProtocol, Sendable {
    public init() {}

    public func startSession() async throws {}

    public func submitTranscript(_ text: String) async {}

    public func pollReview(sessionID: String) async throws -> ReviewPollResponse {
        ReviewPollResponse(sessionID: sessionID, status: .pending, review: nil)
    }

    public func sendDegradedTextMessage(_ text: String) async throws -> PostMessageResponse {
        PostMessageResponse(
            sessionID: "placeholder",
            reply: "",
            channel: "text",
            generator: "placeholder"
        )
    }

    public func endSession() async {}
}

public extension Container {
    var featureFlagResolver: Factory<FeatureFlagResolver> {
        self { FeatureFlagResolverFactory.makeFirstWaveResolver() }.singleton
    }

    var bootstrapClient: Factory<BootstrapClientProtocol> {
        self {
            ResolverBackedBootstrapClient(resolver: self.featureFlagResolver())
        }.singleton
    }

    var socketTransport: Factory<SocketTransportProtocol> {
        // Factory erase-to-protocol; actor is created once per container scope.
        self { URLSessionSocketTransport() as SocketTransportProtocol }.singleton
    }

    var networkPluginFactory: Factory<NetworkPluginFactoryProtocol> {
        self { DefaultNetworkPluginFactory() }.singleton
    }

    var networkClient: Factory<NetworkClientProtocol> {
        self { self.networkPluginFactory().makeNetworkClient() }.singleton
    }

    var sessionAPIClient: Factory<SessionAPIClientProtocol> {
        self {
            SessionAPIClient(
                network: self.networkClient(),
                baseURL: self.appEnvironment().apiBaseURL
            )
        }.singleton
    }

    var corpusAPIClient: Factory<CorpusAPIClientProtocol> {
        self {
            CorpusAPIClient(
                network: self.networkClient(),
                baseURL: self.appEnvironment().apiBaseURL
            )
        }.singleton
    }

    var authTokenStore: Factory<AuthTokenStoreProtocol> {
        self {
            SecureAuthTokenStore(
                storage: self.secureStorage(),
                idGenerator: self.idGenerator()
            )
        }.singleton
    }

    var corpusCacheStore: Factory<CorpusCacheStoreProtocol> {
        self { JSONCorpusCacheStore() }.singleton
    }

    var networkMonitor: Factory<NetworkMonitorProtocol> {
        self { NWPathNetworkMonitor() }.singleton
    }

    var audioEngine: Factory<AudioEngineProtocol> {
        self { PlaceholderAudioEngine() }.shared
    }

    var speechSessionClient: Factory<SpeechSessionClientProtocol> {
        self {
            DefaultSpeechSessionClient(
                api: self.sessionAPIClient(),
                tokens: self.authTokenStore(),
                transport: self.socketTransport()
            )
        }.shared
    }

    var corpusClient: Factory<CorpusClientProtocol> {
        self {
            DefaultCorpusClient(
                api: self.corpusAPIClient(),
                sessionAPI: self.sessionAPIClient(),
                tokens: self.authTokenStore()
            )
        }.shared
    }

    var featurePluginRegistry: Factory<FeaturePluginRegistryProtocol> {
        self { StaticFeaturePluginRegistry() }.singleton
    }

    var logger: Factory<LoggingProtocol> {
        self { OSLogLogger() }.singleton
    }

    var tracker: Factory<TrackerClientProtocol> {
        self { ConsoleTracker() }.singleton
    }

    var secureStorage: Factory<SecureStorageProtocol> {
        self { KeychainSecureStorage() }.singleton
    }

    var clock: Factory<ClockProtocol> {
        self { SystemClock() }.singleton
    }

    var idGenerator: Factory<IDGeneratorProtocol> {
        self { SystemIDGenerator() }.singleton
    }

    var appEnvironment: Factory<AppEnvironment> {
        self { AppEnvironment.current }.singleton
    }
}
