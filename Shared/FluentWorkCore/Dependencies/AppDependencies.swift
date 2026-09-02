import FactoryKit
import FluentWorkDiagnostics
import FluentWorkFeatureFlags
import FluentWorkNetworking
import FluentWorkPluginSupport
import Foundation
import TGFeatureFlag

public protocol BootstrapClientProtocol: Sendable {
    func loadBootstrap() async throws -> BootstrapResult
}
public enum AudioEngineEvent: Equatable, Sendable {
    case speechStarted
    case speechEnded
    case pcmChunk(Data)
    case failed(String)
}


public protocol AudioEngineProtocol: Sendable {
    func startCapture() async throws
    func events() -> AsyncStream<AudioEngineEvent>
    func stopCapture() async
    func play(frame: WSAudioFrame) async
    func interruptNow() async
}

/// Decodes an inbound `WSAudioFrame` (Opus payload) into 16 kHz mono
/// interleaved PCM16 frames ready for `AVAudioPlayerNode` scheduling.
///
/// The wire format is fixed at the speaking-room boundary — both the
/// Volcengine path and any test fallback produce the same PCM shape so
/// the AVAudioPlayerNode can stay format-locked once attached.
public protocol WSAudioFrameDecoder: Sendable {
    /// Decode one `WSAudioFrame` into 16 kHz mono interleaved PCM16 bytes.
    ///
    /// Returned `Data.count` is always a multiple of 2 (one `Int16` per sample).
    /// The PCM shape is the same shape `LiveAudioEngine` emits on the
    /// capture side, which keeps the loopback test round-trip tight.
    func decode(_ frame: WSAudioFrame) async throws -> Data
}

/// Decoder that treats `opusPayload` as already-PCM16 bytes.
///
/// Useful for:
///   - Unit tests that drive the speaking-room wiring without a Volcengine
///     decoder
///   - The first day of B13 integration, when the backend can still send raw
///     PCM fallback frames while we confirm the wire format
///
/// Validates the payload length is a multiple of two (PCM16 sample width) so
/// a malformed fallback frame surfaces a clear error instead of corrupting
/// the player node's buffer queue.
public struct RawPCM16FrameDecoder: WSAudioFrameDecoder {
    public enum Error: Swift.Error, Equatable {
        case oddSampleCount(Int)
    }

    public init() {}

    public func decode(_ frame: WSAudioFrame) async throws -> Data {
        guard frame.opusPayload.count.isMultiple(of: 2) else {
            throw Error.oddSampleCount(frame.opusPayload.count)
        }
        return frame.opusPayload
    }
}

/// Decoder that targets the Volcengine Opus pipeline.
///
/// This is a deliberate stub — the real implementation lands in B13 once the
/// Volcengine SDK is on the SDK dependency list and the SDK wrapper type is
/// selected. Until then, constructing this decoder and asking it to decode
/// surfaces a clear `notAvailable` error so the engine can degrade instead of
/// crashing the speaking room.
public struct VolcengineOpusFrameDecoder: WSAudioFrameDecoder {
    public enum Error: Swift.Error, Equatable {
        case notAvailable
    }

    public init() {}

    public func decode(_ frame: WSAudioFrame) async throws -> Data {
        throw Error.notAvailable
    }
}

public protocol SpeechSessionClientProtocol: Sendable {
    func startSession() async throws
    /// Sends a `user.speech.start` or `user.speech.end` frame to the backend.
    /// `turnID` is the current user turn identifier (e.g. "turn-1") used by the
    /// backend for badge hit dedupe. Pass `nil` when `started` is true.
    /// `text` is the optional client ASR transcription result (B13). Pass `nil`
    /// to fall back to server-side ASR.
    func sendSpeechBoundary(started: Bool, turnID: String?, text: String?) async throws
    func sendAudioPCM(_ data: Data) async throws
    func submitTranscript(_ text: String) async
    func transportEvents() -> AsyncStream<SocketTransportEvent>
    func pollReview(sessionID: String) async throws -> ReviewPollResponse
    func sendDegradedTextMessage(_ text: String) async throws -> PostMessageResponse
    func endSession() async
}

public protocol NetworkPluginFactoryProtocol: Sendable {
    func makeNetworkClient() -> NetworkClientProtocol
}

public struct StaticBootstrapClient: BootstrapClientProtocol {
    public let snapshot: BootstrapSnapshot
    public let authInfo: AuthInfo?

    public init(snapshot: BootstrapSnapshot = .preview, authInfo: AuthInfo? = nil) {
        self.snapshot = snapshot
        self.authInfo = authInfo
    }

    public func loadBootstrap() async throws -> BootstrapResult {
        BootstrapResult(snapshot: snapshot, authInfo: authInfo)
    }
}

/// Loads flags via TGFeatureFlag `FeatureFlagResolver`, then maps into Redux domain snapshot.
/// Also ensures a valid guest token exists before bootstrap completes.
public struct ResolverBackedBootstrapClient: BootstrapClientProtocol {
    public let resolver: FeatureFlagResolver
    public let preferredSurfaceProvider: @Sendable () -> WorkspaceSurface
    public let sessionAPI: SessionAPIClientProtocol
    public let tokenStore: AuthTokenStoreProtocol

    public init(
        resolver: FeatureFlagResolver = FeatureFlagResolverFactory.makeFirstWaveResolver(),
        preferredSurfaceProvider: @escaping @Sendable () -> WorkspaceSurface = { .speakingRoom },
        sessionAPI: SessionAPIClientProtocol,
        tokenStore: AuthTokenStoreProtocol
    ) {
        self.resolver = resolver
        self.preferredSurfaceProvider = preferredSurfaceProvider
        self.sessionAPI = sessionAPI
        self.tokenStore = tokenStore
    }

    public func loadBootstrap() async throws -> BootstrapResult {
        // Ensure guest token exists and capture auth info
        let authInfo = try await ensureGuestToken()
        
        _ = await resolver.refresh()
        let remote = resolver.snapshot(for: AppFeatureFlag.allCases)
        let snapshot = BootstrapSnapshot(
            featureFlags: FeatureFlagSnapshotMapper.map(remote),
            preferredSurface: preferredSurfaceProvider()
        )
        
        return BootstrapResult(snapshot: snapshot, authInfo: authInfo)
    }
    
    /// Ensures a valid guest token exists and returns auth info.
    /// If no token exists, issues a new guest token from the backend.
    private func ensureGuestToken() async throws -> AuthInfo {
        let deviceID = try await tokenStore.deviceID()

        // Check if we already have a valid access token
        if let existingToken = try await tokenStore.accessToken(), !existingToken.isEmpty {
            // Parse existing token to get user info
            if let userID = try await tokenStore.userID() {
                let isGuest = try await tokenStore.isGuest()
                return AuthInfo(userID: userID, isGuest: isGuest, deviceID: deviceID)
            }
        }

        // No token exists, issue a new guest token
        let tokenResponse = try await sessionAPI.issueGuest(deviceID: deviceID)
        try await tokenStore.save(tokens: tokenResponse, deviceID: deviceID)

        return AuthInfo(
            userID: tokenResponse.userID,
            isGuest: tokenResponse.isGuest,
            deviceID: deviceID
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
    private nonisolated let stream: AsyncStream<AudioEngineEvent>

    public init() {
        self.stream = AsyncStream { continuation in
            continuation.finish()
        }
    }

    public func startCapture() async throws {}

    public func stopCapture() async {}

    public func events() -> AsyncStream<AudioEngineEvent> {
        stream
    }

    public func play(frame: WSAudioFrame) async {}

    public func interruptNow() async {}
}

public final class PlaceholderSpeechSessionClient: SpeechSessionClientProtocol, Sendable {
    public init() {}

    public func startSession() async throws {}

    public func submitTranscript(_ text: String) async {}

    public func sendSpeechBoundary(started: Bool, turnID: String?, text: String?) async throws {}

    public func sendAudioPCM(_ data: Data) async throws {}

    public func transportEvents() -> AsyncStream<SocketTransportEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

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
            ResolverBackedBootstrapClient(
                resolver: self.featureFlagResolver(),
                preferredSurfaceProvider: self.preferredSurfaceProvider(),
                sessionAPI: self.sessionAPIClient(),
                tokenStore: self.authTokenStore()
            )
        }.singleton
    }

    var preferredSurfaceProvider: Factory<@Sendable () -> WorkspaceSurface> {
        self {
            // Production default: speakingRoom
            // Debug builds can override via `container.preferredSurfaceProvider.register { { .workbench } }`
            { .speakingRoom }
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
        self {
            let baseClient = self.networkPluginFactory().makeNetworkClient()
            return AuthenticatedNetworkClient(
                baseClient: baseClient,
                tokenRefreshCoordinator: self.tokenRefreshCoordinator()
            )
        }.singleton
    }

    var sessionAPIClient: Factory<SessionAPIClientProtocol> {
        self {
            // Use base network client directly (no auth interceptor)
            // to avoid circular dependency: sessionAPIClient is used
            // by tokenRefreshCoordinator, which is used by networkClient
            let baseClient = self.networkPluginFactory().makeNetworkClient()
            return SessionAPIClient(
                network: baseClient,
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

    var dailyReadAPIClient: Factory<DailyReadAPIClientProtocol> {
        self {
            DailyReadAPIClient(
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

    var tokenRefreshCoordinator: Factory<TokenRefreshCoordinator> {
        self {
            TokenRefreshCoordinator(
                tokenStore: self.authTokenStore(),
                sessionAPI: self.sessionAPIClient(),
                expiryBuffer: 5 * 60  // 5 minutes
            )
        }.singleton
    }

    var corpusCacheStore: Factory<CorpusCacheStoreProtocol> {
        self { JSONCorpusCacheStore() }.singleton
    }

    var corpusOutboxStore: Factory<CorpusOutboxStoreProtocol> {
        self { JSONCorpusOutboxStore() }.singleton
    }

    var corpusSyncMetadataStore: Factory<CorpusSyncMetadataStoreProtocol> {
        self { JSONCorpusSyncMetadataStore() }.singleton
    }

    var networkMonitor: Factory<NetworkMonitorProtocol> {
        self { NWPathNetworkMonitor() }.singleton
    }

    var audioEngine: Factory<AudioEngineProtocol> {
        self {
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                // XCTest path: keep `PlaceholderAudioEngine` so unit tests that
                // exercise reducer/middleware wiring without AVFoundation can
                // still resolve `audioEngine()` without spinning up an
                // `AVAudioEngine` graph.
                return PlaceholderAudioEngine()
            }
            #if canImport(AVFoundation)
            // Day-one real wiring uses the raw PCM16 decoder so loopback
            // tests can drive the speaking-room pipeline without the
            // Volcengine SDK; the production decoder swap happens behind the
            // I12 decoder factory once B13 main-lines Opus encoding.
            return LiveAudioEngine(decoder: self.wsAudioFrameDecoder())
            #else
            return PlaceholderAudioEngine()
            #endif
        }.shared
    }

    var wsAudioFrameDecoder: Factory<any WSAudioFrameDecoder> {
        self { RawPCM16FrameDecoder() }.singleton
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

    var dailyReadClient: Factory<DailyReadClientProtocol> {
        self {
            DefaultDailyReadClient(
                api: self.dailyReadAPIClient(),
                sessionAPI: self.sessionAPIClient(),
                tokens: self.authTokenStore()
            )
        }.shared
    }

    var dailyReadAudioPlayer: Factory<DailyReadAudioPlayerProtocol> {
        self {
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                return StubDailyReadAudioPlayer()
            }
            return DailyReadAudioPlayer()
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

    var clientASRTranscriber: Factory<ClientASRTranscriber> {
        self {
            // B13/B14: Default to server-relay ASR from the voice gateway (Volcengine Duplex).
            // The authoritative transcript arrives via WSS `client.asr.transcription` frame
            // and is dispatched directly to the store — this transcriber is a no-op.
            //
            // To run local Apple Speech instead (e.g., in environments where the voice
            // gateway does not have Volcengine credentials):
            //   container.clientASRTranscriber.register { AppleSpeechClientASRTranscriber() }
            ServerRelayASRTranscriber()
        }.singleton
    }
}
