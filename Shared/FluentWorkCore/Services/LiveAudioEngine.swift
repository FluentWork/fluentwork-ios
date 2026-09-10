@preconcurrency import AVFoundation
import FluentWorkNetworking
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

    public init(
        sessionManager: any AudioSessionManaging = DefaultAudioSessionManager(),
        decoder: any WSAudioFrameDecoder = RawPCM16FrameDecoder(),
        interruptionObserver: any AudioInterruptionObserving = AudioInterruptionObserver(),
        requestMicrophonePermission: @escaping @Sendable () async -> Bool = {
            await MicrophonePermission.request()
        },
        startEngineForPlayback: @escaping @Sendable (AVAudioEngine) throws -> Void = { try $0.start() }
    ) {
        self.startEngineForPlayback = startEngineForPlayback
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
        let inputFormat = inputNode.inputFormat(forBus: 0)

        // Validate format before starting — empty formats mean no usable
        // input device, which we surface as a recoverable error instead of
        // letting AVAudioEngine's internal precondition fire.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioEngineError.invalidFormat(
                "No usable audio input (sampleRate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount)). Check microphone permission or device audio input."
            )
        }

        // Install tap BEFORE startCapture calls engine.start(). The tap must
        // be in place when the engine comes online, otherwise the first audio
        // buffers are lost and the speaking-room UI never sees `.speechStarted`.
        let hadInstalledTap = hasInstalledTap
        if hadInstalledTap {
            inputNode.removeTap(onBus: 0)
        }

        let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat)
        self.sourceFormat = inputFormat
        self.converter = converter
        // Rebuild from the configured mode, not from the initializer defaults.
        // A bare `AudioSpeechActivityTracker()` here silently reinstated the
        // auto-VAD configuration for every session.
        self.speechTracker = .forMode(speechBoundaryMode)
        self.playbackGate.reset()
        self.hasInstalledTap = false

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // # weak-required: actor value after guard; Task retains this engine for one buffer hop.
            Task {
                await self.processInput(buffer)
            }
        }
        hasInstalledTap = true

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
                throw AudioEngineError.audioSessionConflict(
                    "Audio engine failed to start: \(error.localizedDescription)"
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
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { return }

        inputNode.removeTap(onBus: 0)
        hasInstalledTap = false
        sourceFormat = inputFormat
        converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat)

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
        //
        // Use the callback-based overload (not `await scheduleBuffer`) — the
        // `async` overload blocks until the buffer is consumed by the running
        // engine, which never happens when `startCapture()` hasn't been called
        // (the common case in tests that only assert on the gate / decoder
        // path). Queuing with a no-op completion handler returns immediately
        // and the audio graph is irrelevant for the assertions we make.
        playerNode.scheduleBuffer(buffer, at: nil, options: []) {}
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
            playerNode.play()
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
            guard shouldResume else { return }
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
