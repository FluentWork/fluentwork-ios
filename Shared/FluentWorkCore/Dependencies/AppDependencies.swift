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
    case engineConfigurationChanged(isRunning: Bool)
    /// Whether engine-level voice processing (AEC) actually took effect for the
    /// capture session that just started, plus the format the tap ended up
    /// with. Informational — not a session failure.
    ///
    /// It exists because AEC's *effect* can only be judged on a device, but
    /// whether the switch was even on is a fact the log can carry. Without it
    /// a failed device run cannot distinguish "AEC is not good enough" from
    /// "AEC was never enabled" — and only the second one is a bug.
    case voiceProcessing(String)
    /// How the utterance that just ended was closed, and what the endpointing
    /// looked like. Informational — the session proceeds either way.
    ///
    /// It exists because the hold that ends a turn is a **guess** about how
    /// long a speaker pauses before finishing a sentence, and nothing ever
    /// measured it. Raising the guess would only trade one guess for another.
    ///
    /// `trailingSilenceMs` is the number that decides: how long the room waited
    /// after the last sound before submitting. When it lands on the hold, the
    /// hold is what closed the turn — which is the case where someone pausing
    /// to think is cut off mid-sentence.
    ///
    /// Both numbers are optional so "not measured" and "measured as zero" stay
    /// distinguishable: a turn closed by a tap has no trailing silence to
    /// report, and reporting `0` would read as "stopped and finished instantly",
    /// which is a real and different case.
    case speechEndpointed(reason: String, windowMs: Int?, trailingSilenceMs: Int?)
    /// A captured buffer never became PCM, so it never became a `pcmChunk`.
    ///
    /// Emitted **once per capture session**, not once per buffer: at 48 kHz the
    /// tap fires ~86 times a second, and a line per buffer would bury the fact
    /// it exists to reveal.
    ///
    /// It exists because this was the last silent gate on the uplink. A capture
    /// graph that reports a healthy tap (`tap=48000Hz/1ch`) while every buffer
    /// fails conversion looks *identical* to a graph that is working — until you
    /// notice the gateway received no audio and the turn timed out. The client
    /// could not say why it sent nothing; now it can.
    case captureDropped(reason: String)
    /// Capture is fully committed: the tap is in and the engine is up.
    ///
    /// Emitted at the very end of `startCapture()`, so its presence proves the
    /// graph was armed rather than merely that it got as far as the format read.
    ///
    /// `wasRunning` says the start was skipped because the engine was believed
    /// to be up; `running` is the state at this instant. Measured on device
    /// 2026-09-20: armed with `running: false` and a tap that never fired.
    /// `session` is the shared `AVAudioSession`'s category/mode at this instant,
    /// as reported by `LiveAudioEngine.describeSession()`.
    ///
    /// The two booleans say *that* the engine is not running; only this says
    /// *why*, and the two candidate causes are indistinguishable without it. An
    /// `AVAudioEngine` stops itself when its session is reconfigured — without
    /// executing a line of the engine's code — so `running: false` after a
    /// successful start and a successful keep-alive kick means something outside
    /// the engine took the session. A category other than `.playAndRecord` names
    /// the thief. Measured on device 2026-09-24.
    ///
    /// The start's own failure, as opposed to this later stop, is reported by
    /// `EngineStart.Failure.detail` in the thrown `AudioEngineError` — that is
    /// the only channel that reaches the log.
    case captureArmed(wasRunning: Bool, running: Bool, session: String)
    /// The tap delivered its first buffer of this capture session.
    ///
    /// Once per session, like `captureDropped`. Absent means the tap was
    /// installed and never fired, which is a different bug from every one that
    /// has a format or a converter in it.
    case captureFirstBuffer
    /// The system interruption lifted. `droppedBuffers` is how many the
    /// `isSystemInterrupted` guard swallowed while it lasted.
    ///
    /// Emitted once per interruption, not once per buffer — at 48 kHz the tap
    /// keeps firing through a phone call, so a per-buffer line would be thousands
    /// a minute and would bury the interruption itself.
    ///
    /// The count is the point. Dropping buffers during an interruption is
    /// correct, so nothing was ever worth reporting — but the guard was also
    /// **silent**, which made "the system interrupted us" and "the microphone
    /// produced nothing" the same observation from the outside. It is the
    /// difference between a user whose call was briefly in the way and a session
    /// that was broken before the call arrived.
    case captureInterruptionLifted(droppedBuffers: Int)
    /// The result of trying to start the render cycle at session start.
    ///
    /// Emitted once per `startCapture()`, right before `captureArmed`. The
    /// microphone does not deliver a single buffer until something plays, and
    /// `.connecting` waits for the microphone — so this is what breaks the
    /// circle, and the pair of this event and `captureFirstBuffer` is the whole
    /// verdict: `started: true` + no first buffer means the kick did not work,
    /// `started: false` with a `detail` means it never got the chance.
    ///
    /// `detail` names which of the six exits was taken. The previous attempt at
    /// this (`ff2c142`, a silent `AVAudioSourceNode`) reported nothing at all,
    /// so "the fix did not work" and "the fix was never installed" were
    /// indistinguishable — which is the failure mode this project keeps paying
    /// for, and the reason this event exists rather than a comment.
    case captureKick(started: Bool, detail: String)
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

/// 采集与播放的引擎契约。
///
/// 它**同时是** `AudioSink`：`TTSPlaybackCoordinator` 的播放出口就是这个引擎，
/// 不是另一个对象。这是有意的 —— `playbackRetired` 守卫住在 `play(pcm:)` 里，
/// 让引擎之外的实现去播会静默绕过它，症状是「结束练习后又被迟到帧拉起来」。
///
/// 引擎侧曾经还有一道 `AudioPlaybackGate`（按序列号的水印）。它已随
/// `play(frame:)` 一起删除。传输层那道同类的水印（`BargeInAudioGate`）也在
/// 2026-09-22 删掉了，理由是同一个：序号说不出一个帧属于哪一轮。
///
/// 所以**现在没有任何一层按序号丢弃音频**——两道都去掉了，而不是把两处合成一处。
/// 归属与丢弃都由 `TTSPlaybackCoordinator` 在轮次轴上判定，并留下
/// `tts_frame_dropped` 埋点。
public protocol AudioEngineProtocol: AudioSink {
    func startCapture() async throws
    func events() -> AsyncStream<AudioEngineEvent>
    func stopCapture() async
    /// 播放已经解码好的 16kHz mono PCM16。
    ///
    /// 带轮次归属的帧走这条：轮次归属由 `TTSPlaybackCoordinator` 判定，
    /// 引擎侧那道「按序列号的水位线」管不到它（也没有序列号可用）。
    ///
    /// 是**要求**而不是扩展默认实现 —— 同 `setVoiceProcessingEnabled` 那条注释
    /// 的理由：默认实现会在 `any AudioEngineProtocol` 上静态派发，测试全绿而真机
    /// 不出声。
    func play(pcm: Data) async
    func interruptNow() async
    /// Hold TTS without dumping scheduled buffers. Cancel of 结束练习 resumes.
    func pausePlayback() async
    /// Release a `pausePlayback()` hold and continue scheduled TTS.
    func resumePlayback() async
    /// Drop in-progress VAD speech without emitting `.speechEnded`.
    /// Used by I20 recording abort so middleware does not send `user.speech.end`.
    func discardActiveSpeech() async
    func setSpeechBoundaryMode(_ mode: SpeechBoundaryMode) async
    /// Declares whether the session should run engine-level voice processing
    /// (AEC). Applied when the capture graph is built, since the unit may only
    /// be toggled while the engine is stopped.
    ///
    /// A **requirement**, not just a defaulted extension method. An
    /// extension-only method is dispatched statically when called through
    /// `any AudioEngineProtocol` — the default would run, the real engine's
    /// implementation would not, and the switch would never reach the audio
    /// path while every test that used the concrete type still passed.
    func setVoiceProcessingEnabled(_ enabled: Bool) async
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
    public func setVoiceProcessingEnabled(_ enabled: Bool) async {}
    public func beginManualSpeech() async {}
    public func endManualSpeech() async {}
    public func reconfigureForRouteChange() async {}
    public func pausePlayback() async {}
    public func resumePlayback() async {}
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

/// Decoder that treats `payload` as already-PCM16 bytes.
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
        guard frame.payload.count.isMultiple(of: 2) else {
            throw Error.oddSampleCount(frame.payload.count)
        }
        return frame.payload
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
    /// Opens a practice session.
    ///
    /// `continueFromSessionID` names an earlier session to open *with* —
    /// the id travels on `session.start` and the server decides whether it
    /// may be read (it compares owners and answers "not found" either
    /// way). Nil starts from nothing, which is what every other caller
    /// wants.
    func startSession(continueFromSessionID: String?) async throws
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
    /// Interrupts the in-flight reply (barge-in).
    ///
    /// Its own entry point, not a mode of `sendSpeechBoundary` or of a
    /// transcript submission. A barge-in is the only thing that puts
    /// `control.interrupt` on the wire, and it puts nothing else there.
    ///
    /// This replaced `submitTranscript("__interrupt__")`: a method named for
    /// submitting a transcript, whose body ignored every string except a magic
    /// sentinel. The real carrier for a client transcript is
    /// `sendSpeechBoundary(started: false, turnID:text:)`'s `text` — so the old
    /// method was not a redundant way to submit text, it was a misleading one.
    /// See `docs/70_tts_wss_refactor/19_打断改成显式入口.md`.
    func sendInterrupt() async
    func sendRescueRequest() async
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

/// 「当前进程是不是测试进程」。
///
/// 原先三处守卫各自判 `XCTestConfigurationFilePath` —— 那是 **XCTest 的运行器**
/// 才会设的变量。本仓跑的是 Swift Testing（`swift test`），该变量为 `nil`
/// （2026-09-22 实测），于是三道守卫**从不生效**：
///
/// - `audioEngine`：37 条与音频无关的接线测试各自构造了一个真的
///   `LiveAudioEngine`（真 `AVAudioSession`、真麦克风；`deinit` 还会无条件去碰
///   输入节点）。它们只是顺手解析了整个依赖图，本意是拿 `PlaceholderAudioEngine`。
/// - `dailyReadAudioPlayer`：测试拿到真播放器，而它直接操作真 `AVAudioSession`。
/// - `backgroundTaskPort`：iOS 上测试拿到 `UIKitBackgroundTaskPort`。
///
/// 改判「XCTest 是否被加载」：`swift test` 经由 `swiftpm-testing-helper` 运行、
/// `xcodebuild test` 经由 XCTest 运行器运行，两者都能解析出 `XCTestCase`；
/// 生产 app 不链接 XCTest，所以为 `nil`。
///
/// 两条都留着：环境变量那条覆盖「运行器在、但类还没加载」的极早时刻。
/// 钉住它的是 `AudioEngineResolutionTests`。
enum TestProcess {
    static var isRunning: Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        return NSClassFromString("XCTestCase") != nil
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

    public func play(pcm: Data) async {}

    public func interruptNow() async {}

    public func discardActiveSpeech() async {}
}

public final class PlaceholderSpeechSessionClient: SpeechSessionClientProtocol, Sendable {
    public init() {}

    public func startSession(continueFromSessionID: String?) async throws {}

    public func activeSessionID() async -> String? { nil }

    public func sendInterrupt() async {}

    public func sendRescueRequest() async {}

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

    var sessionHistoryAPIClient: Factory<SessionHistoryAPIClientProtocol> {
        self {
            SessionHistoryAPIClient(
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
            if TestProcess.isRunning {
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
            #if DEBUG
            // 麦克风替身（`FW_MOCK_MIC=1`）：采集交给脚本，播放仍走真引擎。
            // 验证音频链路时用它而不是真麦克风 —— 理由见 `MockAudioEngine`。
            if let script = MockAudioEngine.Script.fromEnvironment() {
                #if canImport(AVFoundation)
                return MockAudioEngine(
                    script: script,
                    playback: LiveAudioEngine(
                        sessionManager: self.audioSessionManager(),
                        decoder: self.wsAudioFrameDecoder()
                    ),
                    preparePlaybackSession: {
                        try self.audioSessionManager().configure(for: .playback)
                    }
                )
                #endif
            }
            #endif
            if TestProcess.isRunning {
                // 测试进程：给 `PlaceholderAudioEngine`，不要构造 `AVAudioEngine` 图。
                // 判据不能只看 `XCTestConfigurationFilePath`（Swift Testing 下为 nil），
                // 理由与实测见 `TestProcess`。
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

    /// 带轮次归属的帧的解码 seam（`TTSPlaybackCoordinator` 用）。
    ///
    /// 复用 `wsAudioFrameDecoder` 这个工厂，而不是另起一个绑定：两个调用点必须
    /// 解同一个 codec，否则又回到「双解码器」那条老路。
    var audioFrameDecoder: Factory<any AudioFrameDecoder> {
        self { WSAudioFrameDecoderAdapter(decoder: self.wsAudioFrameDecoder()) }.cached
    }

    // 这里曾经有一个 `ttsDecoder` 绑定，指向 `MockTTSDecoder`（只记录、不出声）。
    // 2026-09-12 的静音事故就是它：网关一发 `ai.tts.start`，帧被旧派发器认领，
    // 音频从此交给一台录音机。Stage 4 把整条并行路径删掉了 —— 现在带轮次归属的帧
    // 走 `audioFrameDecoder`（真实解码）→ `AudioSink.play(pcm:)`（真的出声）。
    //
    // **没有回滚开关。** 契约 `meta 83_` §2 原写「网关停发 `ai.tts.start`，帧自动退回
    // legacy 路径，客户端不用改任何一行」—— 那条 fallback 已随 legacy 路径一起删除
    // （`d004869`）：无归属的帧现在被 `TTSPlaybackCoordinator` 判
    // `.dropped(reason: .unknownTurn)`。网关停发 start 的产物是**整轮静音**，
    // 不是降级出声；要回滚只能回滚客户端提交。

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
            if TestProcess.isRunning {
                return StubDailyReadAudioPlayer()
            }
            return DailyReadAudioPlayer()
        }.shared
    }

    var sessionHistoryClient: Factory<SessionHistoryClientProtocol> {
        self {
            DefaultSessionHistoryClient(
                api: self.sessionHistoryAPIClient(),
                sessionAPI: self.sessionAPIClient(),
                tokens: self.authTokenStore()
            )
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
