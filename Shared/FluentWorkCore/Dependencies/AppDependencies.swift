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
    case interruptedBySystem
    case systemInterruptEnded
    /// Headset unplug / old output gone. Informational — not a session failure.
    case routeChanged(String)
    /// Whether engine-level voice processing (AEC) actually took effect for the
    /// capture session that just started, plus the format the tap ended up
    /// with. Informational — not a session failure.
    ///
    /// It exists because AEC's *effect* can only be judged on a device, but
    /// whether the switch was even on is a fact the log can carry. Without it
    /// a failed device run cannot distinguish "AEC is not good enough" from
    /// "AEC was never enabled" — and only the second one is a bug.
    case voiceProcessing(String)
    case failed(String)
}

/// How `LiveAudioEngine` decides user-speech start/end.
///
/// `tapToStart` is the speaking-room default. Auto VAD is opt-in via
/// `AppFeatureFlag.voiceVadAuto`; `manual` is the legacy tap-to-talk kept as a
/// fallback.
public enum SpeechBoundaryMode: Equatable, Sendable {
    /// Energy opens and closes the utterance.
    case autoVAD
    /// The tap opens the utterance, a stable silence closes it. One gesture per
    /// turn: the user never has to press a second button to submit.
    case tapToStart
    /// The tap opens and the tap closes (legacy).
    case manual
}

public protocol AudioEngineProtocol: Sendable {
    func startCapture() async throws
    func events() -> AsyncStream<AudioEngineEvent>
    func stopCapture() async
    func play(frame: WSAudioFrame) async
    func interruptNow() async
    /// Drop in-progress VAD speech without emitting `.speechEnded`.
    /// Used by I20 recording abort so middleware does not send `user.speech.end`.
    func discardActiveSpeech() async
    func setSpeechBoundaryMode(_ mode: SpeechBoundaryMode) async
    /// Emit `.speechStarted` for tap-to-talk. No-op if speech is already open.
    func beginManualSpeech() async
    /// Emit `.speechEnded` for tap-to-talk. No-op if speech is not open.
    func endManualSpeech() async
    /// Headset unplug / Bluetooth switch: re-apply full-duplex session and
    /// reinstall the input tap. No-op if capture is not running.
    func reconfigureForRouteChange() async
}

extension AudioEngineProtocol {
    public func setSpeechBoundaryMode(_ mode: SpeechBoundaryMode) async {}
    /// Declares whether the session should run engine-level voice processing.
    ///
    /// Same shape as `setSpeechBoundaryMode`: the middleware turns a feature
    /// flag into an intent, and the engine applies it when it builds the
    /// capture graph. It cannot be applied on demand — voice processing may
    /// only be toggled while the engine is stopped, and `startCapture()` is
    /// what starts it.
    public func setVoiceProcessingEnabled(_ enabled: Bool) async {}
    public func beginManualSpeech() async {}
    public func endManualSpeech() async {}
    public func reconfigureForRouteChange() async {}
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
/// **Status (2026-09-02)**: deliberate stub. The backend
/// (`provider_volc_duplex.go`) currently relays only `ai.text.delta` and the
/// `client.asr.transcription` control frame — it does **not** forward
/// `response.output_audio.delta` as binary WS frames, so iOS never receives
/// Opus data in production and this decoder is never invoked.
///
/// This stub stays in place because:
///
/// 1. The day AI audio relay ships (B15+), the iOS path will activate with
///    zero protocol changes — only the decoder body needs swapping.
/// 2. The `WSAudioFrame` / `WSAudioFrameCodec` framing layer (sequence-gated
///    drop, `UInt32` BE header) is the **transport** abstraction, separate
///    from the codec. Removing the framing now would force a larger rewrite
///    the moment backend starts sending audio bytes again.
///
/// If you need to wire the real Volcengine Opus decoder, replace `decode`
/// with a call into the Volcengine SDK's `OpusDecoder` and remove the
/// `notAvailable` error case. The protocol shape (`WSAudioFrame` →
/// `Data` PCM16) does not need to change.
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
    /// The session id currently bound by the client (nil before start / after end).
    func activeSessionID() async -> String?
    /// Sends a `user.speech.start` or `user.speech.end` frame to the backend.
    /// `turnID` is the current user turn identifier (e.g. "turn-1") used by the
    /// backend for badge hit dedupe. Pass `nil` when `started` is true.
    /// `text` is the optional client ASR transcription result (B13). Pass `nil`
    /// to fall back to server-side ASR.
    func sendSpeechBoundary(started: Bool, turnID: String?, text: String?) async throws
    /// I20 T-I20-1: abort an in-progress recording turn. Not `session.end`.
    func sendTurnAbort(turnID: String, outcome: TurnOutcome) async throws
    func sendAudioPCM(_ data: Data) async throws
    func submitTranscript(_ text: String) async
    func transportEvents() -> AsyncStream<SocketTransportEvent>
    func pollReview(sessionID: String) async throws -> ReviewPollResponse
    func sendDegradedTextMessage(_ text: String) async throws -> PostMessageResponse
    func endSession() async
    /// Disconnects the WSS transport without sending `session.end`.
    func closeTransport() async
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

    public func discardActiveSpeech() async {}
}

public final class PlaceholderSpeechSessionClient: SpeechSessionClientProtocol, Sendable {
    public init() {}

    public func startSession() async throws {}

    public func activeSessionID() async -> String? { nil }

    public func submitTranscript(_ text: String) async {}

    public func sendSpeechBoundary(started: Bool, turnID: String?, text: String?) async throws {}

    public func sendTurnAbort(turnID: String, outcome: TurnOutcome) async throws {}

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

    public func closeTransport() async {}
}

public extension Container {
    var featureFlagResolver: Factory<FeatureFlagResolver> {
        self { FeatureFlagResolverFactory.makeFirstWaveResolver() }.cached
    }

    var bootstrapClient: Factory<BootstrapClientProtocol> {
        self {
            ResolverBackedBootstrapClient(
                resolver: self.featureFlagResolver(),
                preferredSurfaceProvider: self.preferredSurfaceProvider(),
                sessionAPI: self.sessionAPIClient(),
                tokenStore: self.authTokenStore()
            )
        }.cached
    }

    var preferredSurfaceProvider: Factory<@Sendable () -> WorkspaceSurface> {
        self {
            // Production default: speakingRoom
            // Debug builds can override via `container.preferredSurfaceProvider.register { { .workbench } }`
            { .speakingRoom }
        }.cached
    }

    var socketTransport: Factory<SocketTransportProtocol> {
        // Factory erase-to-protocol; actor is created once per container scope.
        self { URLSessionSocketTransport() as SocketTransportProtocol }.cached
    }

    var networkPluginFactory: Factory<NetworkPluginFactoryProtocol> {
        self { DefaultNetworkPluginFactory() }.cached
    }

    var networkClient: Factory<NetworkClientProtocol> {
        self {
            let baseClient = self.networkPluginFactory().makeNetworkClient()
            return AuthenticatedNetworkClient(
                baseClient: baseClient,
                tokenRefreshCoordinator: self.tokenRefreshCoordinator()
            )
        }.cached
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
        }.cached
    }

    var corpusAPIClient: Factory<CorpusAPIClientProtocol> {
        self {
            CorpusAPIClient(
                network: self.networkClient(),
                baseURL: self.appEnvironment().apiBaseURL
            )
        }.cached
    }

    var dailyReadAPIClient: Factory<DailyReadAPIClientProtocol> {
        self {
            DailyReadAPIClient(
                network: self.networkClient(),
                baseURL: self.appEnvironment().apiBaseURL
            )
        }.cached
    }

    var authTokenStore: Factory<AuthTokenStoreProtocol> {
        self {
            SecureAuthTokenStore(
                storage: self.secureStorage(),
                idGenerator: self.idGenerator()
            )
        }.cached
    }

    var tokenRefreshCoordinator: Factory<TokenRefreshCoordinator> {
        self {
            TokenRefreshCoordinator(
                tokenStore: self.authTokenStore(),
                sessionAPI: self.sessionAPIClient(),
                expiryBuffer: 5 * 60  // 5 minutes
            )
        }.cached
    }

    var corpusCacheStore: Factory<CorpusCacheStoreProtocol> {
        self { JSONCorpusCacheStore() }.cached
    }

    var corpusOutboxStore: Factory<CorpusOutboxStoreProtocol> {
        self { JSONCorpusOutboxStore() }.cached
    }

    var corpusSyncMetadataStore: Factory<CorpusSyncMetadataStoreProtocol> {
        self { JSONCorpusSyncMetadataStore() }.cached
    }

    var networkMonitor: Factory<NetworkMonitorProtocol> {
        self { NWPathNetworkMonitor() }.cached
    }

    var audioSessionManager: Factory<AudioSessionManaging> {
        self { DefaultAudioSessionManager() }.cached
    }

    var backgroundTaskPort: Factory<BackgroundTaskPorting> {
        self {
            #if os(iOS)
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                return NoOpBackgroundTaskPort()
            }
            return UIKitBackgroundTaskPort()
            #else
            return NoOpBackgroundTaskPort()
            #endif
        }.cached
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
            return LiveAudioEngine(
                sessionManager: self.audioSessionManager(),
                decoder: self.wsAudioFrameDecoder()
            )
            #else
            return PlaceholderAudioEngine()
            #endif
        }.shared
    }

    var wsAudioFrameDecoder: Factory<any WSAudioFrameDecoder> {
        self { RawPCM16FrameDecoder() }.cached
    }

    var ttsDecoder: Factory<any TTSDecoder> {
        // Unique so parallel tests do not share a recording mock, and so each
        // middleware instance owns its own decoder for the session lifetime.
        self { MockTTSDecoder() }.unique
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
        self { StaticFeaturePluginRegistry() }.cached
    }

    var logger: Factory<LoggingProtocol> {
        self { OSLogLogger() }.cached
    }

    var tracker: Factory<TrackerClientProtocol> {
        // Per-container, not process singleton. Production still has one
        // instance via `Container.shared`. Tests can register a CapturingTracker
        // on a local `Container()` without racing other suites' `reset()`.
        self { ConsoleTracker() }.shared
    }

    var secureStorage: Factory<SecureStorageProtocol> {
        self { KeychainSecureStorage() }.cached
    }

    var clock: Factory<ClockProtocol> {
        self { SystemClock() }.cached
    }

    /// B15 total cap and the per-stage processing budgets.
    ///
    /// Registered rather than compiled in so a test can inject a short budget
    /// and observe an overrun in milliseconds. Waiting out the real 15s ASR
    /// budget in `swift test` is why the overrun path had no coverage.
    var processingTimeouts: Factory<ProcessingTimeouts> {
        // Deliberately **not** `.cached`. This is a stateless value type, so
        // caching buys nothing — but it does make the registration sticky
        // process-wide, and a test that injects a short budget to exercise a
        // timeout then leaks it into every test running concurrently. Measured:
        // an 80ms `connectWait` in one test failed two others ~half the time,
        // with nothing in either test to suggest why.
        self { .standard }
    }

    var idGenerator: Factory<IDGeneratorProtocol> {
        self { SystemIDGenerator() }.cached
    }

    var appEnvironment: Factory<AppEnvironment> {
        self { AppEnvironment.current }.cached
    }
}
