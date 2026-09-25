@preconcurrency import AVFoundation
import FluentWorkNetworking
import FluentWorkObjCSupport
import Foundation

public actor LiveAudioEngine: AudioEngineProtocol {
    final class ConversionConsumptionState: @unchecked Sendable {
        var consumed = false
    }

    let engine = AVAudioEngine()
    nonisolated static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!
    // Sendable immutable state exposed nonisolated so `events()` can stay a
    // synchronous protocol requirement.
    private nonisolated let stream: AsyncStream<AudioEngineEvent>
    let continuation: AsyncStream<AudioEngineEvent>.Continuation

    var converter: AVAudioConverter?
    var sourceFormat: AVAudioFormat?
    private var hasInstalledTap = false
    var captureFirstBufferSeen = false
    /// Emitted at most once per capture session: the tap fires ~86 times a
    /// second at 48 kHz, so a line per buffer would bury the fact it reveals.
    var captureDropReported = false
    /// Buffers the `isSystemInterrupted` guard swallowed during the interruption
    /// in progress. Reset when one begins, reported when it lifts.
    var interruptionDroppedBuffers = 0
    var speechTracker = AudioSpeechActivityTracker.forMode(.manual)
    /// When the current utterance opened, so its length can be reported
    /// alongside how it closed. The tracker cannot hold this itself: it has no
    /// clock — every timestamp it uses is handed in by the caller.
    var speechStartedAt: ContinuousClock.Instant?
    var speechBoundaryMode: SpeechBoundaryMode = .manual
    /// Whether the session asked for engine-level voice processing (AEC).
    ///
    /// An intent, not a state: it is applied when the capture graph is built,
    /// because voice processing may only be toggled while the engine is
    /// stopped — and `startCapture()` is what starts it.
    var voiceProcessingRequested = false
    /// What voice processing is doing on the current graph. Read back from the
    /// node, never inferred from the request, and stored only so
    /// `reconfigureForRouteChange` can tell whether a route change moved it.
    var voiceProcessingActive = false
    let clock = ContinuousClock()

    // Playback graph, lazy-attached on the first frame. `AVAudioPlayerNode` is
    // not `Sendable` but is actor-isolated here, so access from `play(pcm:)`
    // and `interruptNow()` is serialized.
    let playerNode = AVAudioPlayerNode()
    var playerAttached = false
    /// A player that loops silence for the session's whole life, so the render
    /// cycle is running before anything is asked of the microphone: the
    /// microphone does not deliver a buffer until something plays.
    ///
    /// Deliberately **not** `playerNode`. That node is the TTS player, and
    /// `interruptNow()` stops and resets it on every barge-in — sharing it
    /// would put the microphone back to sleep exactly when the user is talking.
    let keepAliveNode = AVAudioPlayerNode()
    var keepAliveAttached = false
    /// Whether the looping buffer is already queued. Scheduling it twice would
    /// queue a second loop over the first.
    var keepAliveBufferScheduled = false
    /// Silence at 16 kHz mono, looping. One second is long enough that the loop
    /// point is irrelevant and short enough to stay trivial to render.
    let keepAliveBuffer: AVAudioPCMBuffer? = {
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: LiveAudioEngine.targetFormat,
                frameCapacity: 16_000
            )
        else { return nil }
        // `frameLength` before the memset, or `mDataByteSize` still describes an
        // empty buffer and nothing gets zeroed. Zeroed through the buffer list
        // rather than `int16ChannelData`, which is not the channel accessor for
        // an interleaved format.
        buffer.frameLength = 16_000
        for entry in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            if let data = entry.mData {
                memset(data, 0, Int(entry.mDataByteSize))
            }
        }
        return buffer
    }()

    /// Set when `stopCapture()` tears the audio graph down. Capture and playback
    /// share one `AVAudioEngine`, so ending a session retires **both**
    /// directions. `AVAudioPlayerNode.play()` on a node whose engine has been
    /// torn down raises an uncaught `NSException` ("player started when in a
    /// disconnected state") — it does not throw, so refusing the frame is the
    /// only safe answer.
    var playbackRetired = false

    /// 结束练习 confirmation is on screen. The player is paused and incoming
    /// TTS still schedules, but `play()` is not called until `resumePlayback()`.
    /// Dumping the queue here would make cancel unable to continue the reply.
    var playbackPaused = false
    /// 排进播放器的 buffer 计数。只为 `_testScheduledBufferCount()` 存在。
    var scheduledBufferCount = 0

    /// Captured at the moment `interruptNow()` is requested, so tests can assert
    /// the local-silence budget without depending on hardware audio output.
    var lastInterruptRequestedAt: ContinuousClock.Instant?
    var isSystemInterrupted = false

    private let sessionManager: any AudioSessionManaging
    let decoder: any WSAudioFrameDecoder
    let interruptionObserver: any AudioInterruptionObserving
    private let requestMicrophonePermission: @Sendable () async -> Bool
    /// How the playback direction brings the shared engine up. Injectable
    /// because the branch that matters — the engine refusing to start — is the
    /// one a healthy device will not take.
    let startEngineForPlayback: @Sendable (AVAudioEngine) throws -> Void
    /// Turns on engine-level voice processing and returns the read-back rather
    /// than `Void`, because "we asked and nothing threw" is not the same fact as
    /// "the unit is engaged". Injectable because the branch that matters — the
    /// device refusing the unit — is one a healthy device will not take, and
    /// because it keeps `swift test` off the real API.
    let applyVoiceProcessing: @Sendable (AVAudioInputNode) throws -> Bool
    /// 装上采集 tap。可注入**只为**让 `swift test` 不碰本机输入设备 —— 用真实实现时，
    /// 在有输入设备的开发机上这一步会打开麦克风（系统亮指示、CI 机器开始录音）。
    private let installCaptureTap: @Sendable (AVAudioInputNode, AVAudioFormat, @escaping AVAudioNodeTapBlock) -> NSError?
    /// 启动采集引擎。与 `installCaptureTap` 分成两个口子而不是一个：只堵住 tap，
    /// `engine.start()` 仍会因为输入节点被访问而打开设备 —— 半堵的替身比不堵更糟，
    /// 因为它看起来已经安全了。
    private let startCaptureEngine: @Sendable (AVAudioEngine) throws -> Void

    private let removeCaptureTap: @Sendable (AVAudioEngine) -> Void

    public init(
        sessionManager: any AudioSessionManaging = DefaultAudioSessionManager(),
        decoder: any WSAudioFrameDecoder = RawPCM16FrameDecoder(),
        interruptionObserver: any AudioInterruptionObserving = AudioInterruptionObserver(),
        requestMicrophonePermission: @escaping @Sendable () async -> Bool = {
            await MicrophonePermission.request()
        },
        startEngineForPlayback: @escaping @Sendable (AVAudioEngine) throws -> Void = { try $0.start() },
        applyVoiceProcessing: @escaping @Sendable (AVAudioInputNode) throws -> Bool = { node in
            // Two failure shapes, two mechanisms, both needed here.
            // `setVoiceProcessingEnabled` is a throwing Swift call, so a refusal
            // arrives as a Swift error; asking while the engine is running fails
            // the other way — an `AVAEInternal` "required condition is false"
            // raise — and an `NSException` is invisible to `do/catch`.
            var raised: NSError?
            var thrown: Error?
            _ = FWTryCatch({
                do { try node.setVoiceProcessingEnabled(true) } catch { thrown = error }
            }, &raised)
            if let raised { throw raised }
            if let thrown { throw thrown }
            return node.isVoiceProcessingEnabled
        },
        installCaptureTap: @escaping @Sendable (AVAudioInputNode, AVAudioFormat, @escaping AVAudioNodeTapBlock) -> NSError? = { node, format, block in
            var raised: NSError?
            let installed = FWTryCatch({
                node.installTap(onBus: 0, bufferSize: 1_024, format: format, block: block)
            }, &raised)
            guard !installed else { return nil }
            return raised ?? NSError(
                domain: "com.fluentwork.capture-tap",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "unknown"]
            )
        },
        startCaptureEngine: @escaping @Sendable (AVAudioEngine) throws -> Void = { try $0.start() },
        removeCaptureTap: @escaping @Sendable (AVAudioEngine) -> Void = { $0.inputNode.removeTap(onBus: 0) },
    ) {
        self.startEngineForPlayback = startEngineForPlayback
        self.applyVoiceProcessing = applyVoiceProcessing
        self.installCaptureTap = installCaptureTap
        self.startCaptureEngine = startCaptureEngine
        self.removeCaptureTap = removeCaptureTap
        let pair = AsyncStream.makeStream(
            of: AudioEngineEvent.self,
            bufferingPolicy: .bufferingNewest(64)
        )
        self.stream = pair.stream
        self.continuation = pair.continuation
        self.sessionManager = sessionManager
        self.decoder = decoder
        self.interruptionObserver = interruptionObserver
        self.requestMicrophonePermission = requestMicrophonePermission
    }

    deinit {
        if hasInstalledTap {
            removeCaptureTap(engine)
        }
        engine.stop()
        continuation.finish()
    }

    nonisolated public func events() -> AsyncStream<AudioEngineEvent> {
        stream
    }

    public func startCapture() async throws {
        // Permission before activating the session, or activation fails with
        // error 1 when it has not been granted yet.
        let granted = await requestMicrophonePermission()
        guard granted else {
            throw AudioEnginePermissionError.microphoneDenied
        }

        try sessionManager.configure(for: .fullDuplex)

        // Access `inputNode` FIRST so the graph has at least one node attached
        // before `engine.start()`. Starting without one asserts
        // `inputNode != nullptr || outputNode != nullptr` and crashes the app.
        let inputNode = engine.inputNode

        // Voice processing is enabled *before* any format is read, because
        // enabling is what changes the input node's shape. `prepareCaptureNode`
        // owns both halves as one operation; read-before-enable does not throw,
        // it silently builds a converter and a tap against a stream that no
        // longer exists.
        //
        // Gated on the engine being stopped even here: a playback frame that
        // outlived its session brings the engine up through
        // `startPlaybackIfNeeded()`, and toggling voice processing on a running
        // engine raises rather than returning an error.
        let preparation = try prepareCaptureNode(
            inputNode,
            skipEnableReason: engine.isRunning ? "engine already running" : nil
        )
        let inputFormat = preparation.format
        // Reported before the engine starts, so a session that dies during
        // `engine.start()` still leaves behind whether AEC was even on.
        continuation.yield(.voiceProcessing(preparation.report))

        // Guarded rather than assigned blind: a converter that failed to build
        // would become `nil`, `convertToPCM16` would return `nil` for every
        // buffer, and `processInput` would drop them all in silence.
        //
        // Built *before* the old tap is torn down. Removing the tap is
        // irreversible in this window and `hasInstalledTap` is what two other
        // paths act on, so throwing between the two would leave the flag
        // claiming a tap that no longer exists.
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else {
            throw AudioEngineError.invalidFormat(
                "Could not convert \(Self.describe(inputFormat)) to \(Self.describe(Self.targetFormat)). Check microphone permission or device audio input."
            )
        }
        Self.applyCaptureChannelMap(converter, from: inputFormat)

        // Install the tap BEFORE `engine.start()`, or the first audio buffers
        // are lost and the speaking-room UI never sees `.speechStarted`.
        if hasInstalledTap {
            inputNode.removeTap(onBus: 0)
            hasInstalledTap = false
        }

        // Wrapped, and this one is not speculative: `installTap` is the
        // documented abort site for engine-level voice processing, raising
        // `AVAEGraphNode.mm … CreateRecordingTap:
        // (IsFormatSampleRateAndChannelCountValid(format))` when the format
        // handed to it does not match what the node produces.
        if let installRaised = installCaptureTap(inputNode, inputFormat, { [weak self] buffer, _ in
            guard let self else { return }
            // # weak-required: actor value after guard; Task retains this engine for one buffer hop.
            Task {
                await self.processInput(buffer)
            }
        }) {
            throw AudioEngineError.invalidFormat(
                "Could not tap \(Self.describe(inputFormat)) (voiceProcessing=\(preparation.voiceProcessingActive)): \(installRaised.localizedDescription). Check microphone permission or device audio input."
            )
        }

        // Committed together, and only once there is a tap to use them.
        hasInstalledTap = true
        captureDropReported = false
        captureFirstBufferSeen = false
        sourceFormat = inputFormat
        self.converter = converter
        // Rebuild from the configured mode, not from the initializer defaults,
        // or every session silently runs with the auto-VAD configuration.
        speechTracker = .forMode(speechBoundaryMode)

        // Build the WHOLE graph before the engine starts — including the
        // playback nodes. Attaching and connecting into a *live* render graph
        // and then calling `play()` in the same synchronous block leaves the
        // node looking disconnected to AVFoundation, and `play()` raises
        // "player started when in a disconnected state" rather than returning.
        attachPlayerIfNeeded()
        attachKeepAliveIfNeeded()

        // `start()` returning is not the same as the engine running. It can come
        // back without throwing and leave the engine stopped, and nothing used
        // to check: the session went on to advertise a microphone it did not
        // have, `startCapture()` returned success, and the only symptom was a
        // turn the gateway never heard. Silence is this project's one
        // unacceptable failure, so it fails here instead.
        let start = armEngine()
        if let failure = start.failure {
            // Tear down the tap just installed so a retry from a clean state
            // does not trip the "tap already installed" precondition. Do not
            // start interruption observation — the engine never came up.
            if hasInstalledTap {
                inputNode.removeTap(onBus: 0)
                hasInstalledTap = false
            }
            // Voice processing gets a mention because it adds a failure this
            // message would otherwise mis-describe: with it on, the input
            // node's output format and the output node's input format have to
            // agree, so a start failure can be a format mismatch rather than
            // another app holding the session — "close your music app" would be
            // the wrong advice.
            let voiceProcessingNote = preparation.voiceProcessingActive
                ? ". Voice processing is on (\(Self.describe(inputFormat))); its input and output formats must match."
                : ""
            throw AudioEngineError.audioSessionConflict(failure.detail + voiceProcessingNote)
        }

        // The engine is up, so the playback direction is usable again. Only
        // cleared once the start succeeded — a session that failed to come up
        // must not advertise a graph it does not have.
        playbackRetired = false
        playbackPaused = false
        startInterruptionObservation()

        // Kick the render cycle before returning. `.connecting` waits for the
        // microphone to prove itself, and the microphone does not deliver a
        // single buffer until something plays, so a session that armed and
        // played nothing could never become ready.
        let kick = startKeepAlive()
        continuation.yield(.captureKick(started: kick.started, detail: kick.detail))

        // The last line of `startCapture`, so its presence proves the graph was
        // armed — not merely that it reached the format read.
        continuation.yield(.captureArmed(
            wasRunning: start.wasRunning,
            running: engine.isRunning,
            // Read here, at the moment the answer is `false`, because the two
            // ways the engine can already be stopped — the system interrupted
            // us, or another component reconfigured the shared session — leave
            // no other trace. See `describeSession()`.
            session: Self.describeSession()
        ))
    }

    func armEngine() -> EngineStart.Outcome {
        let wasRunning = engine.isRunning
        var startError: String?
        if !wasRunning {
            do {
                try startCaptureEngine(engine)
            } catch {
                startError = error.localizedDescription
            }
        }
        guard !engine.isRunning else {
            return EngineStart.Outcome(wasRunning: wasRunning, failure: nil)
        }
        return EngineStart.Outcome(
            wasRunning: wasRunning,
            failure: EngineStart.Failure(
                error: startError,
                interrupted: isSystemInterrupted,
                session: Self.describeSession()
            )
        )
    }

    public func reconfigureForRouteChange() async {
        do {
            try sessionManager.configure(for: .fullDuplex)
        } catch {
            // Keep the existing graph. Killing the session on a headset unplug
            // is worse than a brief format mismatch.
            return
        }

        guard hasInstalledTap else { return }

        let inputNode = engine.inputNode

        // This path **never toggles** voice processing. Toggling requires
        // stopping the engine, which throws away the assistant's in-flight
        // playback mid-reply, and it would land while the previous tap is still
        // installed on bus 0, changing the node's produced format underneath a
        // tap that describes the old one.
        //
        // Nothing is lost: the state is *read back* either way, so a unit the
        // route change dropped yields the raw format and a unit that survived
        // yields the processed one. Both are consistent.
        guard let preparation = try? prepareCaptureNode(inputNode, skipEnableReason: "route change") else {
            // No usable format after the route change. Keep the existing graph
            // and let the interruption observer surface the failure.
            return
        }
        let inputFormat = preparation.format

        // Rebuild only when the node's stream actually moved. A route change
        // that leaves the format and the unit state alone used to tear the tap
        // down and reinstall it regardless, dropping whatever audio was
        // buffered mid-turn.
        guard sourceFormat?.isEqual(inputFormat) != true
            || voiceProcessingActive != preparation.voiceProcessingActive
        else {
            return
        }

        // Built before anything is torn down, so a converter that will not build
        // leaves the working chain in place instead of swapping in a dead one.
        // This path cannot throw — it is a reaction to a route change, not a
        // session start — so the alternative to refusing here is installing a
        // tap whose converter is `nil`, which is silent.
        guard let replacement = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else {
            return
        }
        Self.applyCaptureChannelMap(replacement, from: inputFormat)

        // Wrapped for the same reason `startCapture`'s install is: this is the
        // documented abort site, and this path runs while a session is live.
        inputNode.removeTap(onBus: 0)
        hasInstalledTap = false
        if let installRaised = installCaptureTap(inputNode, inputFormat, { [weak self] buffer, _ in
            guard let self else { return }
            Task {
                await self.processInput(buffer)
            }
        }) {
            // No tap, and `hasInstalledTap` already says so — the session keeps
            // running silent rather than taking the process down with it.
            continuation.yield(.failed("could not reinstall the capture tap after a route change: \(installRaised.localizedDescription)"))
            return
        }

        hasInstalledTap = true
        sourceFormat = inputFormat
        converter = replacement
        voiceProcessingActive = preparation.voiceProcessingActive
        continuation.yield(.voiceProcessing(preparation.report))

        if let failure = armEngine().failure {
            continuation.yield(
                .failed("could not restart the engine after a route change: \(failure.detail)")
            )
        }
    }

    public func stopCapture() async {
        stopInterruptionObservation()
        // Retire before anything that yields or mutates the graph. Leftover TTS
        // frames from a socket that has not closed yet still call `play(pcm:)`;
        // once this flag is set they drop instead of restarting the player (and
        // instead of `.failed`, which would kill the process-lifetime audio
        // pump).
        playbackRetired = true
        playbackPaused = false
        let shouldRemoveTap = hasInstalledTap
        hasInstalledTap = false
        // Also stop any in-flight AI playback, and detach the nodes so the next
        // session re-attaches them against a graph that actually exists.
        // Leaving them attached is what makes the *next* `play()` dangerous:
        // the graph is about to be torn down, and `playerAttached` would go on
        // claiming the node is fine.
        for step in PlaybackTeardown.steps(
            playerAttached: playerAttached,
            engineRunning: engine.isRunning,
            tapInstalled: shouldRemoveTap,
            keepAliveAttached: keepAliveAttached
        ) {
            switch step {
            case .stopPlayer:
                playerNode.stop()
            case .resetPlayer:
                playerNode.reset()
            case .stopKeepAlive:
                keepAliveNode.stop()
            case .resetKeepAlive:
                keepAliveNode.reset()
                // The queued loop went with the reset, so the next session has
                // to schedule it again rather than assume it is still there.
                keepAliveBufferScheduled = false
            case .stopEngine:
                engine.stop()
            case .removeTap:
                removeCaptureTap(engine)
            case .detachPlayer:
                engine.detach(playerNode)
                playerAttached = false
            case .detachKeepAlive:
                engine.detach(keepAliveNode)
                keepAliveAttached = false
            }
        }

        if let emitted = speechTracker.reset() {
            yieldSpeechBoundary(emitted)
        }
        lastInterruptRequestedAt = nil
        isSystemInterrupted = false

        // NOTE: Do NOT deactivate the audio session here. Deactivating while AI
        // audio is still playing (during aiSpeaking→waitingUser transitions)
        // uninitializes the AVAudioEngine internal graph, causing
        // `required condition is false: inputNode != nullptr || outputNode != nullptr`
        // on the next `engine.start()` or any node access. The session stays
        // active across the full speaking-room session; it is only deactivated
        // when the app explicitly ends the session or moves to background.
    }
}
