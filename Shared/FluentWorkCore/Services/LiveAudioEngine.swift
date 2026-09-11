@preconcurrency import AVFoundation
import FluentWorkNetworking
import FluentWorkObjCSupport
import Foundation

public enum AudioEnginePermissionError: Error {
    case microphoneDenied
}

public enum AudioEngineError: Error {
    case invalidFormat(String)
    case audioSessionConflict(String)
}

struct AudioSpeechActivityTracker: Sendable {
    /// Endpointing hold for auto-VAD. Nobody taps in that mode, so silence is
    /// the only signal and a short hold is what keeps turn-taking responsive.
    static let autoVADSilenceHold: Duration = .milliseconds(1500)
    /// Endpointing hold for tap-to-start. Deliberately much longer: the user
    /// opened the turn on purpose and is usually mid-thought, and a learner
    /// pausing to find a word routinely exceeds the auto-VAD hold. A 1.5s hold
    /// cut turns off mid-sentence, so the auto-submit is a fallback here rather
    /// than the expected way to finish — 「说完了」 is always available.
    ///
    /// Raised 4s → 8s after the mode fix landed: until then this value never
    /// reached the audio path (see `forMode`), so the first real tap-to-start
    /// session was also the first chance to judge the hold, and a pause to
    /// think still submitted the turn.
    static let tapToStartSilenceHold: Duration = .milliseconds(8000)

    private(set) var isSpeechActive = false
    private(set) var lastSpeechAt: ContinuousClock.Instant?
    let speechThreshold: Float
    var silenceHold: Duration
    /// When false an utterance can only begin via `forceStart()`; energy is
    /// still what closes it. This is the tap-to-start mode: the tap opens the
    /// turn, a stable silence submits it, so a turn costs one gesture instead
    /// of two. Energy must *start* the turn in auto-VAD mode, where nobody taps.
    var autoStart: Bool

    init(
        speechThreshold: Float = 0.015,
        silenceHold: Duration = AudioSpeechActivityTracker.autoVADSilenceHold,
        autoStart: Bool = true
    ) {
        self.speechThreshold = speechThreshold
        self.silenceHold = silenceHold
        self.autoStart = autoStart
    }

    mutating func register(energy: Float, at now: ContinuousClock.Instant) -> AudioEngineEvent? {
        if energy >= speechThreshold {
            lastSpeechAt = now
            guard !isSpeechActive else { return nil }
            guard autoStart else { return nil }
            isSpeechActive = true
            return .speechStarted
        }

        // `lastSpeechAt` stays nil until the user actually speaks, so a tap
        // followed by silence never submits an empty turn — it falls through to
        // the 60s recording abort instead.
        guard isSpeechActive, let lastSpeechAt else { return nil }
        guard now - lastSpeechAt >= silenceHold else { return nil }

        isSpeechActive = false
        self.lastSpeechAt = nil
        return .speechEnded
    }

    mutating func forceStart() -> AudioEngineEvent? {
        guard !isSpeechActive else { return nil }
        isSpeechActive = true
        lastSpeechAt = nil
        return .speechStarted
    }

    mutating func forceEnd() -> AudioEngineEvent? {
        guard isSpeechActive else { return nil }
        discard()
        return .speechEnded
    }

    mutating func reset() -> AudioEngineEvent? {
        let wasActive = isSpeechActive
        discard()
        return wasActive ? .speechEnded : nil
    }

    /// Clear in-progress speech without emitting `.speechEnded`.
    mutating func discard() {
        isSpeechActive = false
        lastSpeechAt = nil
    }

    /// The tracker a boundary mode implies.
    ///
    /// One source of truth for the mode → (`autoStart`, `silenceHold`) mapping.
    /// It used to live inline in `setSpeechBoundaryMode` while every other site
    /// built trackers from the initializer defaults, and the two disagreed:
    /// `startCapture()` runs immediately after the mode is set and rebuilt a
    /// fresh tracker for the session, handing the audio path the auto-VAD
    /// defaults — energy free to open a turn, 1.5s of silence able to close one
    /// — whichever mode the session had actually asked for.
    static func forMode(_ mode: SpeechBoundaryMode) -> AudioSpeechActivityTracker {
        AudioSpeechActivityTracker(
            silenceHold: mode == .tapToStart ? tapToStartSilenceHold : autoVADSilenceHold,
            autoStart: mode == .autoVAD
        )
    }
}

struct AudioPlaybackGate: Sendable {
    private(set) var lastAcceptedSequence: UInt32?
    private(set) var interruptWatermark: UInt32?

    mutating func shouldAccept(_ frame: WSAudioFrame) -> Bool {
        if let interruptWatermark, frame.sequence <= interruptWatermark {
            return false
        }
        lastAcceptedSequence = frame.sequence
        return true
    }

    mutating func markInterrupted() -> UInt32? {
        interruptWatermark = lastAcceptedSequence
        return interruptWatermark
    }

    mutating func reset() {
        lastAcceptedSequence = nil
        interruptWatermark = nil
    }
}

public actor LiveAudioEngine: AudioEngineProtocol {
    private final class ConversionConsumptionState: @unchecked Sendable {
        var consumed = false
    }

    private let engine = AVAudioEngine()
    nonisolated private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!
    // Sendable immutable state exposed nonisolated so `events()` can stay a
    // synchronous protocol requirement.
    private nonisolated let stream: AsyncStream<AudioEngineEvent>
    private let continuation: AsyncStream<AudioEngineEvent>.Continuation

    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var hasInstalledTap = false
    private var speechTracker = AudioSpeechActivityTracker.forMode(.manual)
    private var playbackGate = AudioPlaybackGate()
    private var speechBoundaryMode: SpeechBoundaryMode = .manual
    /// Whether the session asked for engine-level voice processing (AEC).
    ///
    /// An intent, not a state: it is applied when the capture graph is built,
    /// because voice processing may only be toggled while the engine is
    /// stopped — and `startCapture()` is what starts it. Same shape as
    /// `speechBoundaryMode`.
    private var voiceProcessingRequested = false
    /// Whether voice processing actually took effect on the current graph.
    ///
    /// Deliberately separate from the request. A device that refuses voice
    /// processing still captures, just without AEC, and the difference has to
    /// be visible somewhere or a bad echo-cancellation result cannot be told
    /// apart from a switch that never came on.
    private var voiceProcessingActive = false
    private let clock = ContinuousClock()

    // Playback graph (lazy-attached on first frame).
    //
    // AVAudioPlayerNode is not Sendable but is actor-isolated here so access
    // from `play(frame:)` and `interruptNow()` is serialized. The node stays
    // detached until the first frame arrives so construction stays cheap in
    // tests that only exercise the capture / event side.
    private let playerNode = AVAudioPlayerNode()
    private var playerAttached = false

    /// Set when `stopCapture()` tears the audio graph down.
    ///
    /// Capture and playback share one `AVAudioEngine`, so ending a session
    /// retires **both** directions — the player node goes down with the graph.
    /// Retiring it is not bookkeeping: `AVAudioPlayerNode.play()` on a node
    /// whose engine has been torn down raises an uncaught `NSException`
    /// ("player started when in a disconnected state"). It does not throw, so
    /// there is no error to catch and no state to inspect — refusing the frame
    /// is the only safe answer.
    ///
    /// Defaults to `false`: a freshly built engine can play, and a session that
    /// never called `stopCapture()` behaves exactly as before.
    private var playbackRetired = false

    // Barge-in timing — captured at the moment `interruptNow()` is requested so
    // tests can assert the local-silence budget (≤ 200 ms) without depending on
    // hardware audio output.
    private var lastInterruptRequestedAt: ContinuousClock.Instant?
    private var isSystemInterrupted = false

    private let sessionManager: any AudioSessionManaging
    private let decoder: any WSAudioFrameDecoder
    private let interruptionObserver: any AudioInterruptionObserving
    private let requestMicrophonePermission: @Sendable () async -> Bool
    /// How the playback direction brings the shared engine up.
    ///
    /// Injectable for the same reason as `requestMicrophonePermission`: the
    /// branch that matters most is the one a real `AVAudioEngine` on a healthy
    /// device will not take. Here that branch is "the engine refuses to start",
    /// and reaching it with the real implementation is not a recoverable error
    /// — see `startPlaybackIfNeeded()`.
    private let startEngineForPlayback: @Sendable (AVAudioEngine) throws -> Void
    /// Turns on engine-level voice processing and reports whether it is now on.
    ///
    /// Returns the read-back rather than `Void` because "we asked and nothing
    /// threw" is not the same fact as "the unit is engaged" — the call can
    /// succeed and take no effect, which is precisely the case a device log has
    /// to be able to show. Callers use the return value, never the intent.
    ///
    /// Injectable for the same reason as `startEngineForPlayback`: the branch
    /// that matters is the one a healthy device will not take, and here the
    /// branch is "the device refuses voice processing". It also keeps `swift
    /// test` off the real API entirely — the capture path is already entered on
    /// CI as far as the input node, and `docs/19` §4.2 forbids a test from
    /// depending on whether the machine has an audio device.
    private let applyVoiceProcessing: @Sendable (AVAudioInputNode) throws -> Bool

    public init(
        sessionManager: any AudioSessionManaging = DefaultAudioSessionManager(),
        decoder: any WSAudioFrameDecoder = RawPCM16FrameDecoder(),
        interruptionObserver: any AudioInterruptionObserving = AudioInterruptionObserver(),
        requestMicrophonePermission: @escaping @Sendable () async -> Bool = {
            await MicrophonePermission.request()
        },
        startEngineForPlayback: @escaping @Sendable (AVAudioEngine) throws -> Void = { try $0.start() },
        applyVoiceProcessing: @escaping @Sendable (AVAudioInputNode) throws -> Bool = { node in
            // Two failure shapes, two mechanisms, and both are needed here.
            // `setVoiceProcessingEnabled` is a throwing Swift call, so a refusal
            // arrives as a Swift error; but asking while the engine is running
            // is documented to fail the other way — an `AVAEInternal` "required
            // condition is false" raise — and that is an `NSException`, which
            // `do/catch` cannot see. That second shape is the F12–F16 class and
            // the reason `FWTryCatch` exists at all (`docs/44` §3).
            var raised: NSError?
            var thrown: Error?
            _ = FWTryCatch({
                do { try node.setVoiceProcessingEnabled(true) } catch { thrown = error }
            }, &raised)
            if let raised { throw raised }
            if let thrown { throw thrown }
            return node.isVoiceProcessingEnabled
        }
    ) {
        self.startEngineForPlayback = startEngineForPlayback
        self.applyVoiceProcessing = applyVoiceProcessing
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
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation.finish()
    }

    public func startCapture() async throws {
        // Request microphone permission before activating audio session.
        // This prevents activation error 1 from the audio session
        // when permission hasn't been explicitly granted yet.
        let granted = await requestMicrophonePermission()
        guard granted else {
            throw AudioEnginePermissionError.microphoneDenied
        }

        try sessionManager.configure(for: .fullDuplex)

        // Access inputNode FIRST so the audio graph has at least one node
        // attached before `engine.start()`. On devices without an audio input
        // (e.g., iOS simulator without host audio, Mac Catalyst without mic),
        // starting without an attached node asserts:
        //   `inputNode != nullptr || outputNode != nullptr`
        // and crashes the app. Querying the input format forces lazy node
        // creation; only then do we attempt to start.
        let inputNode = engine.inputNode

        // Voice processing is enabled *before* any format is read, because
        // enabling is what changes the input node's shape. `prepareCaptureNode`
        // owns both halves as one operation — read before enable is the silent
        // failure this change exists to prevent, and it is documented there.
        //
        // It also validates the format: empty formats mean no usable input
        // device, which we surface as a recoverable error instead of letting
        // AVAudioEngine's internal precondition fire.
        // Gated on the engine being stopped, even here. `startCapture()` is not
        // only ever the first thing to touch the engine: a playback frame that
        // outlived its session brings the engine up through
        // `startPlaybackIfNeeded()`, and a retry of `startCapture()` then finds
        // it already running. Toggling voice processing there raises rather
        // than returning an error — the F12–F16 class — so it is not attempted.
        let preparation = try prepareCaptureNode(inputNode, attemptEnable: !engine.isRunning)
        let inputFormat = preparation.format
        voiceProcessingActive = preparation.voiceProcessingActive
        // Reported before the engine starts, so a session that dies during
        // `engine.start()` still leaves behind the one fact a device log needs:
        // whether AEC was even on. See `AudioEngineEvent.voiceProcessing`.
        continuation.yield(.voiceProcessing(preparation.report))

        // Install tap BEFORE startCapture calls engine.start(). The tap must
        // be in place when the engine comes online, otherwise the first audio
        // buffers are lost and the speaking-room UI never sees `.speechStarted`.
        let hadInstalledTap = hasInstalledTap
        if hadInstalledTap {
            inputNode.removeTap(onBus: 0)
        }

        // Guarded rather than assigned blind. `AVAudioConverter(from:to:)`
        // returns an Optional and the old line stored it unchecked: a converter
        // that failed to build became `nil`, `convertToPCM16` then returned
        // `nil` for every buffer, and `processInput` dropped them all in
        // silence — capture that looks alive and carries nothing. A format the
        // voice-processing unit changed underneath us would have landed exactly
        // there, which is why the format chain and the engine-level switch were
        // never separable.
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else {
            throw AudioEngineError.invalidFormat(
                "Could not convert \(Self.describe(inputFormat)) to \(Self.describe(Self.targetFormat)). Check microphone permission or device audio input."
            )
        }
        Self.applyCaptureChannelMap(converter, from: inputFormat)
        self.sourceFormat = inputFormat
        self.converter = converter
        // Rebuild from the configured mode, not from the initializer defaults.
        // A bare `AudioSpeechActivityTracker()` here silently reinstated the
        // auto-VAD configuration for every session.
        self.speechTracker = .forMode(speechBoundaryMode)
        self.playbackGate.reset()
        self.hasInstalledTap = false

        // Wrapped, and this one is not speculative. `installTap` is the
        // documented abort site for engine-level voice processing: the reported
        // failure is `AVAEGraphNode.mm … CreateRecordingTap:
        // (IsFormatSampleRateAndChannelCountValid(format))`, raised as an
        // `NSException` when the format handed to the tap does not match what
        // the node produces — which is exactly what voice processing changes.
        // `prepareCaptureNode` is what makes them match; this is what keeps a
        // mismatch from taking the process down if it ever does not.
        var installRaised: NSError?
        let installed = FWTryCatch({
            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
                guard let self else { return }
                // # weak-required: actor value after guard; Task retains this engine for one buffer hop.
                Task {
                    await self.processInput(buffer)
                }
            }
        }, &installRaised)
        guard installed else {
            throw AudioEngineError.invalidFormat(
                "Could not tap \(Self.describe(inputFormat)) (voiceProcessing=\(preparation.voiceProcessingActive)): \(installRaised?.localizedDescription ?? "unknown"). Check microphone permission or device audio input."
            )
        }
        hasInstalledTap = true

        // Build the WHOLE graph before the engine starts — including the
        // playback node.
        //
        // It used to be attached lazily on the first assistant audio frame,
        // which arrives while capture is already running. Attaching and
        // connecting into a *live* render graph and then calling `play()` in
        // the same synchronous block leaves the node looking disconnected to
        // AVFoundation: the connection has not been committed yet, and `play()`
        // raises "player started when in a disconnected state" rather than
        // returning. Every crash so far landed on the first audio frame of a
        // session, which is the only moment attach, connect and play ever
        // happened together.
        attachPlayerIfNeeded()

        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                // If start fails (e.g., another app holds the audio session),
                // tear down the tap we just installed so a retry from a clean
                // state doesn't trip the "tap already installed" precondition.
                // Do not start interruption observation — the engine never came up.
                if hasInstalledTap {
                    inputNode.removeTap(onBus: 0)
                    hasInstalledTap = false
                }
                // Voice processing gets a mention because it adds a failure
                // this message would otherwise mis-describe. With it on, the
                // input node's output format and the output node's input
                // format have to agree, so a start failure can be a format
                // mismatch rather than another app holding the session —
                // "close your music app" would be the wrong advice.
                let voiceProcessingNote = preparation.voiceProcessingActive
                    ? " Voice processing is on (\(Self.describe(inputFormat))); its input and output formats must match."
                    : ""
                throw AudioEngineError.audioSessionConflict(
                    "Audio engine failed to start: \(error.localizedDescription).\(voiceProcessingNote)"
                )
            }
        }
        // The engine is up, so the playback direction is usable again. Only
        // cleared once the start succeeded — a session that failed to come up
        // must not advertise a graph it does not have.
        playbackRetired = false
        startInterruptionObservation()
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

        // A route change can drop voice processing — the unit follows the
        // device pair, and this is the event that announces the pair changed.
        // Re-applying it is only legal while the engine is stopped, and this
        // path routinely runs with it still running, so the toggle is gated.
        //
        // The formats are resolved either way, and they have to be: a tap
        // rebuilt against a format that no longer matches the node is the same
        // silent-death shape `prepareCaptureNode` documents, and a route change
        // is the other moment the format genuinely moves.
        guard let preparation = try? prepareCaptureNode(
            inputNode,
            attemptEnable: !engine.isRunning
        ) else {
            // No usable format after the route change. Keep the existing graph
            // and let the interruption observer surface the failure — killing
            // the session on a headset unplug is worse than a stale chain.
            return
        }
        let inputFormat = preparation.format

        // Built before anything is torn down, so a converter that will not
        // build leaves the working chain in place instead of swapping in a
        // dead one. This path cannot throw — it is a reaction to a route
        // change, not a session start — so the alternative to refusing here is
        // installing a tap whose converter is `nil`, which is silent.
        guard let replacement = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else {
            return
        }
        Self.applyCaptureChannelMap(replacement, from: inputFormat)

        voiceProcessingActive = preparation.voiceProcessingActive
        continuation.yield(.voiceProcessing(preparation.report))

        inputNode.removeTap(onBus: 0)
        hasInstalledTap = false
        sourceFormat = inputFormat
        converter = replacement

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            Task {
                await self.processInput(buffer)
            }
        }
        hasInstalledTap = true

        if !engine.isRunning {
            try? engine.start()
        }
    }

    public func stopCapture() async {
        stopInterruptionObservation()
        let shouldRemoveTap = hasInstalledTap
        hasInstalledTap = false
        if shouldRemoveTap {
            engine.inputNode.removeTap(onBus: 0)
        }
        // Also stop any in-flight AI playback so a session end always leaves
        // the engine silent on both directions, and detach the node so the next
        // session re-attaches it against a graph that actually exists.
        //
        // Leaving it attached is what makes the *next* `play()` dangerous: the
        // graph below is about to be torn down, and `playerAttached` would go on
        // claiming the node is fine. See `playbackRetired`.
        playbackRetired = true
        if playerAttached {
            playerNode.stop()
            engine.detach(playerNode)
            playerAttached = false
        }
        if engine.isRunning {
            engine.stop()
        }

        if let emitted = speechTracker.reset() {
            continuation.yield(emitted)
        }
        playbackGate.reset()
        lastInterruptRequestedAt = nil
        isSystemInterrupted = false

        // NOTE: Do NOT deactivate the audio session here.
        // Deactivating while AI audio is still playing (during aiSpeaking→waitingUser
        // transitions) uninitializes the AVAudioEngine internal graph, causing:
        //   `required condition is false: inputNode != nullptr || outputNode != nullptr`
        // on the next engine.start() or any node access.
        // The session stays active across the full speaking-room session; it is
        // only deactivated when the app explicitly ends the session or moves to
        // background (handled by AppDelegate scene phase changes).
    }

    nonisolated public func events() -> AsyncStream<AudioEngineEvent> {
        stream
    }

    public func play(frame: WSAudioFrame) async {
        // Checked before anything else: after `stopCapture()` the frame has
        // nowhere to go, and every path below ends in a `play()` that raises
        // rather than returns. `endSession` cancels the transport task that
        // feeds this, but cancellation is not instant — the socket still holds
        // frames in flight, and the first one to land here used to take the
        // process down.
        guard !playbackRetired else {
            continuation.yield(.failed("playback retired; dropped audio frame"))
            return
        }
        guard playbackGate.shouldAccept(frame) else { return }

        let pcm: Data
        do {
            pcm = try await decoder.decode(frame)
        } catch {
            continuation.yield(.failed("decode failed: \(error)"))
            return
        }

        guard startPlaybackIfNeeded() else { return }
        guard let buffer = makePCMBuffer(from: pcm) else {
            continuation.yield(.failed("scheduling dropped: PCM length \(pcm.count) not a multiple of 2"))
            return
        }
        // Local barge-in: even after `interruptNow()` is requested we want the
        // already-scheduled chunks to drain, but a fresh `play(frame:)` after
        // a fresh `interruptNow()` should resume cleanly because the gate has
        // been reset by `startCapture`/session re-enter.
        enqueueWithoutWaiting(buffer)
    }

    /// Queues a buffer and returns immediately.
    ///
    /// Deliberately **not** `await playerNode.scheduleBuffer(...)`, which is the
    /// alternative the editor suggests here. That overload returns only once the
    /// buffer has been *rendered*, so awaiting it would pace the gateway's
    /// turn-end burst to real time: a 32-second reply arrives as one burst, and
    /// the middleware's transport loop would spend those 32 seconds inside this
    /// call — text frames, control frames and the next turn's audio all queued
    /// behind it. Returning immediately also keeps the graph irrelevant to the
    /// tests that only assert on the gate / decoder path.
    ///
    /// Extracted into a synchronous function with `completionHandler: nil` for
    /// two reasons: the queue needs no completion bookkeeping, and the "consider
    /// the asynchronous alternative" diagnostic is about handing a closure to
    /// this API from an async context — neither applies once the call has a
    /// signature of its own.
    private func enqueueWithoutWaiting(_ buffer: AVAudioPCMBuffer) {
        playerNode.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }

    /// Queues audio onto the player node and makes sure something is actually
    /// playing it.
    ///
    /// `scheduleBuffer` only enqueues — a node that was never started plays
    /// nothing. Nothing started it, which is why the speaking room stayed
    /// silent even after the gateway began forwarding the assistant's audio.
    /// `interruptNow()` stops the node for barge-in, so this also has to bring
    /// it back on the next frame.
    ///
    /// Returns whether the node is queued onto a running engine. Every caller
    /// must treat `false` as "nothing will play" — the reason this returns a
    /// value instead of being best-effort is the line it guards:
    ///
    /// `AVAudioPlayerNode.play()` does not throw. On a stopped engine it raises
    /// an **uncaught `NSException`** ("player started when in a disconnected
    /// state") and terminates the app. `try? engine.start()` was exactly the
    /// wrong shape here — it swallowed the failure that leaves the engine
    /// stopped, then ran the one call that cannot survive it. That is reachable
    /// whenever an audio frame outlives the session playing it: `stopCapture()`
    /// runs on `endSession`, the socket still holds frames in flight, and the
    /// next one to arrive used to take the process down.
    private func startPlaybackIfNeeded() -> Bool {
        attachPlayerIfNeeded()
        if !engine.isRunning {
            do {
                try startEngineForPlayback(engine)
            } catch {
                continuation.yield(.failed("playback engine did not start: \(error.localizedDescription)"))
                return false
            }
        }
        guard engine.isRunning else {
            continuation.yield(.failed("playback engine is not running; dropped frame"))
            return false
        }
        // `playerAttached` is this actor's cached belief; `playerNode.engine` is
        // what AVFoundation will actually consult. They disagree exactly when
        // the graph was torn down underneath us — deactivating the audio session
        // does that — and "disconnected state" in the raised exception is this
        // condition, not the engine's run state.
        guard playerNode.engine === engine else {
            continuation.yield(.failed("playback node is detached from the engine; dropped frame"))
            playerAttached = false
            return false
        }
        if !playerNode.isPlaying {
            // `play()` raises rather than returning when the node has nothing to
            // play into, and "has nothing to play into" is not a state this
            // layer can read — three device builds died here on the first audio
            // frame of a session. Every precondition above narrows the window;
            // this is what makes the window not matter.
            var raised: NSError?
            guard FWTryCatch({ self.playerNode.play() }, &raised) else {
                continuation.yield(.failed("player start raised: \(raised?.localizedDescription ?? "unknown")"))
                return false
            }
        }
        return true
    }

    public func interruptNow() async {
        lastInterruptRequestedAt = clock.now
        _ = playbackGate.markInterrupted()
        if playerAttached {
            playerNode.stop()
        }
    }

    public func discardActiveSpeech() async {
        speechTracker.discard()
    }

    public func setSpeechBoundaryMode(_ mode: SpeechBoundaryMode) async {
        speechBoundaryMode = mode
        // The endpointing hold belongs to the mode: tap-to-start has to tolerate
        // a speaker pausing to think, auto-VAD does not. `forMode` also hands
        // back a tracker with no speech in flight, which is the `discard()` a
        // mode switch needs. See `AudioSpeechActivityTracker.forMode`.
        speechTracker = .forMode(mode)
    }

    /// Declares whether the next capture graph should run engine-level voice
    /// processing — the echo canceller, noise suppression and AGC that keep the
    /// assistant from hearing its own voice through the speaker.
    ///
    /// Recorded, not applied. Voice processing may only be toggled while the
    /// engine is stopped, so the value takes effect when `startCapture()` builds
    /// the graph. Setting it mid-session is therefore not an error and not a
    /// no-op either: it changes the *next* session, which is what makes the
    /// feature flag usable as a comparison harness on a device.
    public func setVoiceProcessingEnabled(_ enabled: Bool) async {
        voiceProcessingRequested = enabled
    }

    public func beginManualSpeech() async {
        if let emitted = speechTracker.forceStart() {
            continuation.yield(emitted)
        }
    }

    public func endManualSpeech() async {
        if let emitted = speechTracker.forceEnd() {
            continuation.yield(emitted)
        }
    }

    /// Snapshot of the last `interruptNow()` instant for barge-in latency tests.
    /// Public on the actor so tests can read it without exposing the raw clock.
    public func lastInterruptInstant() -> ContinuousClock.Instant? {
        lastInterruptRequestedAt
    }

    func startInterruptionObservation() {
        interruptionObserver.start { [weak self] kind in
            await self?.handleInterruption(kind)
        }
    }

    func stopInterruptionObservation() {
        interruptionObserver.stop()
    }

    /// Maps AVAudioSession interruption / route changes onto `AudioEngineEvent`.
    /// Does not deactivate the audio session — capture stays configured across
    /// a phone-call-style interrupt so resume does not rebuild the graph.
    func handleInterruption(_ kind: AudioInterruptionKind) {
        switch kind {
        case .began:
            isSystemInterrupted = true
            _ = speechTracker.reset()
            if playerAttached {
                playerNode.pause()
            }
            continuation.yield(.interruptedBySystem)
        case .ended(let shouldResume):
            // docs/22: only resume the speech session when iOS says we may.
            // Do not `playerNode.play()` — interruptedBySystem already asked
            // the machine to stopPlayback, and resume lands in waitingUser.
            //
            // Saying nothing when iOS withholds resume was a trap, not caution.
            // `.began` parked the machine in its suspended phase, and a
            // suspended machine discards every event but five — so with no
            // `.systemInterruptEnded` and no failure, nothing on any path could
            // lift the suspension. Playback stopped, the UI kept rendering the
            // phase it was in, and every later audio event was dropped. The run
            // was over and nothing said so.
            //
            // Ending it is the honest outcome: we may not resume, so we cannot
            // continue, and `.failed` is one of the five events that still land
            // — it reaches the user as a retryable error instead of a freeze.
            guard shouldResume else {
                continuation.yield(.failed("音频被系统中断，本轮练习已停止"))
                return
            }
            isSystemInterrupted = false
            continuation.yield(.systemInterruptEnded)
        case .routeChanged(let reason):
            continuation.yield(.routeChanged(reason))
        }
    }

    private func processInput(_ buffer: AVAudioPCMBuffer) async {
        guard !isSystemInterrupted else { return }
        do {
            guard let pcm = try convertToPCM16(buffer) else { return }
            continuation.yield(.pcmChunk(pcm))
            updateSpeechState(using: pcm)
        } catch {
            continuation.yield(.failed(error.localizedDescription))
        }
    }

    private func updateSpeechState(using pcm: Data) {
        // `.manual` decides both ends with taps, so energy is not consulted at
        // all. The other modes let energy close the utterance; only `.autoVAD`
        // also lets it open one (see AudioSpeechActivityTracker.autoStart).
        guard speechBoundaryMode != .manual else { return }
        let energy = normalizedEnergy(for: pcm)
        let now = clock.now

        if let emitted = speechTracker.register(energy: energy, at: now) {
            continuation.yield(emitted)
        }
    }

    /// What the capture chain resolved to for one graph build.
    struct CapturePreparation {
        /// The format the tap is installed with *and* the format the converter
        /// is built from. One value on purpose: the two have to agree, and when
        /// they do not nothing throws.
        let format: AVAudioFormat
        /// Whether the engine-level voice-processing unit is driving the input.
        let voiceProcessingActive: Bool
        /// One line for the telemetry event. Device logs are read on a phone;
        /// this is what says whether the switch was on before anyone tries to
        /// judge how well it worked.
        let report: String
    }

    /// Turns on engine-level voice processing when the session asked for it,
    /// then reads back the format the tap will actually receive.
    ///
    /// The two are one operation, not two steps, because enabling is what
    /// changes the input node's shape. A caller that reads the format first and
    /// enables second gets the *pre-processing* format while the tap goes on to
    /// receive the processed stream — and that mistake does not throw. The
    /// format is still perfectly valid, so the converter builds, the tap
    /// installs, and every buffer is then dropped at `processInput`'s guard.
    /// Capture that looks alive and carries nothing is the failure shape this
    /// whole change was warned about.
    ///
    /// Enabling is best-effort: a device that refuses voice processing must
    /// still capture. Losing echo cancellation is bad, losing the microphone is
    /// worse — and the outcome is reported either way, so the two can be told
    /// apart afterwards.
    ///
    /// - Parameter attemptEnable: `false` when the engine may be running.
    ///   Voice processing can only be toggled while it is stopped, and asking
    ///   anyway does not fail politely — it raises, which is why this is a
    ///   parameter rather than something the caller is trusted to remember. The
    ///   formats are resolved from the node's real state either way, so a
    ///   caller that cannot toggle still gets the chain that matches what the
    ///   node is producing right now.
    private func prepareCaptureNode(
        _ inputNode: AVAudioInputNode,
        attemptEnable: Bool
    ) throws -> CapturePreparation {
        // The node is asked what it is doing, not what was asked of it. The
        // unit engages on both I/O nodes at once and can already be on from an
        // earlier session, so the request alone does not determine the state —
        // and the state is what decides which format the tap has to use.
        let wasAlreadyOn = inputNode.isVoiceProcessingEnabled
        var isOn = wasAlreadyOn
        var enableFailure: String?

        if voiceProcessingRequested, attemptEnable, !wasAlreadyOn {
            do {
                isOn = try applyVoiceProcessing(inputNode)
            } catch {
                // Surfaced in the report rather than thrown. A device without
                // voice processing gets a working capture chain and a log line
                // that says AEC is off; it does not get a dead microphone.
                enableFailure = error.localizedDescription
                isOn = wasAlreadyOn
            }
        }

        // Read *after* the enable attempt, and gated on the read-back rather
        // than the request. On success these are the processed formats; when
        // the unit is off they are the raw ones, which is what the fallback
        // wants — so a refused or skipped enable leaves the old chain untouched
        // rather than half-converted.
        let rawInput = inputNode.inputFormat(forBus: 0)
        let processedOutput = isOn ? inputNode.outputFormat(forBus: 0) : nil

        guard let format = Self.captureFormat(
            input: rawInput,
            processedOutput: processedOutput,
            voiceProcessingActive: isOn
        ) else {
            throw AudioEngineError.invalidFormat(
                "No usable audio input (voiceProcessing=\(isOn), input=\(Self.describe(rawInput)), processed=\(Self.describe(processedOutput))). Check microphone permission or device audio input."
            )
        }

        return CapturePreparation(
            format: format,
            voiceProcessingActive: isOn,
            report: Self.voiceProcessingReport(
                isOn: isOn,
                wasAlreadyOn: wasAlreadyOn,
                format: format,
                failure: enableFailure
            )
        )
    }

    /// One line for the telemetry event.
    ///
    /// Reports the state the node was found in, the state it ended in, and the
    /// format the tap got — three facts, because a device run that comes back
    /// "AEC did not help" is unreadable without knowing which of them was true.
    /// `alreadyOn` in particular is not noise: the unit is shared across both
    /// I/O nodes and survives between sessions, so "it was on before we asked"
    /// is a different story from "we turned it on".
    nonisolated static func voiceProcessingReport(
        isOn: Bool,
        wasAlreadyOn: Bool,
        format: AVAudioFormat,
        failure: String?
    ) -> String {
        if let failure { return "unavailable: \(failure)" }
        let state = isOn ? "on" : "off"
        let origin = isOn && wasAlreadyOn ? ", alreadyOn" : ""
        return "\(state)\(origin), tap=\(Self.describe(format))"
    }

    /// Chooses the format the capture tap is installed with.
    ///
    /// Without voice processing this is the raw input format — byte for byte
    /// what the chain used before, which is the property the fallback path
    /// depends on. With voice processing the stream the tap receives is the
    /// node's *output* format, not its input format: the unit sits between them.
    ///
    /// Falls back to the raw input format whenever the processed one is missing
    /// or unusable, so a device that half-supports the feature degrades to the
    /// old chain instead of throwing.
    nonisolated static func captureFormat(
        input: AVAudioFormat?,
        processedOutput: AVAudioFormat?,
        voiceProcessingActive: Bool
    ) -> AVAudioFormat? {
        guard voiceProcessingActive else { return usable(input) }
        return usable(processedOutput) ?? usable(input)
    }

    nonisolated private static func usable(_ format: AVAudioFormat?) -> AVAudioFormat? {
        guard let format, format.sampleRate > 0, format.channelCount > 0 else { return nil }
        return format
    }

    /// Takes channel 0 only, when the input carries more than one.
    ///
    /// Voice processing does not hand back a cleaned copy of the microphone
    /// signal — it hands back the microphone channel *plus* the channels the
    /// echo canceller needs to do its job. Only channel 0 is the speaker.
    ///
    /// The default is worse than a bad mix. A discrete multi-channel layout
    /// implies no mapping onto a single channel, so `AVAudioConverter` reports
    /// `channelMap == [-1]`, which the API defines as "this output channel gets
    /// no input at all" — the uplink is *empty*, from a chain that builds
    /// cleanly and throws nothing. That is the same shape as the stale-format
    /// failure `prepareCaptureNode` documents, reached one layer further down.
    ///
    /// A no-op for the single-channel formats that arrive without voice
    /// processing, whose default mapping is already `[0]`, so the fallback path
    /// is untouched. `channelMap` composes with sample-rate conversion — the
    /// conversion below uses the block-based `convert(to:error:withInputFrom:)`
    /// for that reason.
    nonisolated static func applyCaptureChannelMap(
        _ converter: AVAudioConverter,
        from format: AVAudioFormat
    ) {
        guard format.channelCount > 1 else { return }
        converter.channelMap = [0]
    }

    /// Short description of a format for telemetry — sample rate and channel
    /// count are the two numbers that explain a capture chain that came up
    /// wrong.
    nonisolated static func describe(_ format: AVAudioFormat?) -> String {
        guard let format else { return "none" }
        return "\(Int(format.sampleRate))Hz/\(format.channelCount)ch"
    }

    private func convertToPCM16(_ buffer: AVAudioPCMBuffer) throws -> Data? {
        guard let converter, let sourceFormat else { return nil }

        let ratio = Self.targetFormat.sampleRate / max(sourceFormat.sampleRate, 1)
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else {
            return nil
        }

        let consumptionState = ConversionConsumptionState()
        var convertError: NSError?
        let status = converter.convert(to: output, error: &convertError) { _, outStatus in
            if consumptionState.consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumptionState.consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let convertError {
            throw convertError
        }
        guard status != .error, output.frameLength > 0 else { return nil }

        let audioBuffer = output.audioBufferList.pointee.mBuffers
        guard let bytes = audioBuffer.mData else { return nil }
        return Data(bytes: bytes, count: Int(audioBuffer.mDataByteSize))
    }

    /// Test-only hook exposing the tracker a mode switch configured. The
    /// endpointing hold and auto-start both come from the mode, so a unit test
    /// has to read them through the same path `setSpeechBoundaryMode` writes.
    func _testSpeechTracker() -> AudioSpeechActivityTracker {
        speechTracker
    }

    /// Test-only hook reporting whether the player node is running.
    ///
    /// `scheduleBuffer` queues audio onto a node that plays nothing until it is
    /// started, and nothing here ever started it — which is why the assistant
    /// stayed silent even once the gateway began forwarding its audio. Nothing
    /// asserted on this because the existing playback tests only check that the
    /// decoder was reached.
    func _testPlaybackStarted() -> Bool {
        playerNode.isPlaying
    }

    /// Test-only hook reporting whether the shared engine is running.
    ///
    /// `AVAudioPlayerNode.play()` raises — it does not throw — when the engine
    /// is stopped, so "was a node started while the engine was down?" is the
    /// question the crash test has to ask, and it needs both halves of the
    /// answer from the same instant.
    func _testEngineRunning() -> Bool {
        engine.isRunning
    }

    /// Test-only hook reporting what the last graph build resolved to.
    ///
    /// Read through the same field `startCapture` and
    /// `reconfigureForRouteChange` write, because the question worth asking is
    /// not "did the setter store the value" — it is whether the request became
    /// a live voice-processing unit, and those are two different facts.
    func _testVoiceProcessingActive() -> Bool {
        voiceProcessingActive
    }

    /// Test-only hook exercising `convertToPCM16` for the supplied input
    /// buffer + input format. Production callers should keep using
    /// `startCapture()` so the tap stays the source of truth — this hook is
    /// here so the tap-chain format test can verify the converter aligns with
    /// the Volcengine-aligned target (16 kHz, mono, interleaved PCM16)
    /// without pulling in real audio hardware.
    nonisolated func _testConvertToPCM16(_ buffer: AVAudioPCMBuffer, from inputFormat: AVAudioFormat) throws -> Data? {
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else {
            return nil
        }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * (Self.targetFormat.sampleRate / max(inputFormat.sampleRate, 1))) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else {
            return nil
        }
        let consumptionState = ConversionConsumptionState()
        var convertError: NSError?
        let status = converter.convert(to: output, error: &convertError) { _, outStatus in
            if consumptionState.consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumptionState.consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let convertError {
            throw convertError
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        let audioBuffer = output.audioBufferList.pointee.mBuffers
        guard let bytes = audioBuffer.mData else { return nil }
        return Data(bytes: bytes, count: Int(audioBuffer.mDataByteSize))
    }

    private func normalizedEnergy(for pcm: Data) -> Float {
        guard !pcm.isEmpty else { return 0 }
        return pcm.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return 0 }

            var total: Float = 0
            for sample in samples {
                total += abs(Float(sample)) / Float(Int16.max)
            }
            return total / Float(samples.count)
        }
    }

    /// Deliberately *not* wrapped in `FWTryCatch`, unlike `play()`.
    ///
    /// The format here is the source node's own output format, which
    /// `AVAudioEngine` always accepts — the mixer resamples. Voice processing
    /// does not change that: it changes the *output* node's format, and the
    /// mixer→output connection is one the engine manages and re-derives on the
    /// next `stop()`/`start()`. So the raise this would guard is speculative,
    /// while the guard itself is not free: `.failed` ends the middleware's
    /// audio pump for the rest of the process (`docs/49`), which would turn a
    /// one-session playback problem into every later session going silent.
    private func attachPlayerIfNeeded() {
        guard !playerAttached else { return }
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: Self.targetFormat)
        playerAttached = true
    }

    /// Wraps raw 16 kHz mono interleaved PCM16 bytes in an `AVAudioPCMBuffer`
    /// suitable for `AVAudioPlayerNode.scheduleBuffer`.
    ///
    /// The returned buffer's `frameLength` is `payload.count / 2`. If the
    /// payload length is not a multiple of 2, returns `nil` so the caller can
    /// surface a `.failed` event instead of corrupting the player queue.
    private func makePCMBuffer(from payload: Data) -> AVAudioPCMBuffer? {
        guard !payload.isEmpty, payload.count.isMultiple(of: 2) else { return nil }
        let frameCount = AVAudioFrameCount(payload.count / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        guard let target = buffer.audioBufferList.pointee.mBuffers.mData else { return nil }
        return payload.withUnsafeBytes { raw -> AVAudioPCMBuffer? in
            guard let source = raw.baseAddress else { return nil }
            memcpy(target, source, payload.count)
            return buffer
        }
    }
}
