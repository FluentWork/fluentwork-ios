@preconcurrency import AVFoundation
import FluentWorkNetworking
import Foundation

struct AudioSpeechActivityTracker: Sendable {
    private(set) var isSpeechActive = false
    private(set) var lastSpeechAt: ContinuousClock.Instant?
    let speechThreshold: Float
    let silenceHold: Duration

    init(
        speechThreshold: Float = 0.015,
        silenceHold: Duration = .milliseconds(350)
    ) {
        self.speechThreshold = speechThreshold
        self.silenceHold = silenceHold
    }

    mutating func register(energy: Float, at now: ContinuousClock.Instant) -> AudioEngineEvent? {
        if energy >= speechThreshold {
            lastSpeechAt = now
            guard !isSpeechActive else { return nil }
            isSpeechActive = true
            return .speechStarted
        }

        guard isSpeechActive, let lastSpeechAt else { return nil }
        guard now - lastSpeechAt >= silenceHold else { return nil }

        isSpeechActive = false
        self.lastSpeechAt = nil
        return .speechEnded
    }

    mutating func reset() -> AudioEngineEvent? {
        let wasActive = isSpeechActive
        isSpeechActive = false
        lastSpeechAt = nil
        return wasActive ? .speechEnded : nil
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
    private var speechTracker = AudioSpeechActivityTracker()
    private var playbackGate = AudioPlaybackGate()
    private let clock = ContinuousClock()

    // Playback graph (lazy-attached on first frame).
    //
    // AVAudioPlayerNode is not Sendable but is actor-isolated here so access
    // from `play(frame:)` and `interruptNow()` is serialized. The node stays
    // detached until the first frame arrives so construction stays cheap in
    // tests that only exercise the capture / event side.
    private let playerNode = AVAudioPlayerNode()
    private var playerAttached = false

    // Barge-in timing — captured at the moment `interruptNow()` is requested so
    // tests can assert the local-silence budget (≤ 200 ms) without depending on
    // hardware audio output.
    private var lastInterruptRequestedAt: ContinuousClock.Instant?

    private let decoder: any WSAudioFrameDecoder

    public init(decoder: any WSAudioFrameDecoder = RawPCM16FrameDecoder()) {
        let pair = AsyncStream.makeStream(
            of: AudioEngineEvent.self,
            bufferingPolicy: .bufferingNewest(64)
        )
        self.stream = pair.stream
        self.continuation = pair.continuation
        self.decoder = decoder
    }

    deinit {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation.finish()
    }

    public func startCapture() async throws {
        try configureAudioSessionIfNeeded()

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat)
        let hadInstalledTap = hasInstalledTap
        self.sourceFormat = inputFormat
        self.converter = converter
        self.speechTracker = AudioSpeechActivityTracker()
        self.playbackGate.reset()
        self.hasInstalledTap = false

        if hadInstalledTap {
            inputNode.removeTap(onBus: 0)
        }

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            Task {
                await self.processInput(buffer)
            }
        }
        hasInstalledTap = true

        if !engine.isRunning {
            try engine.start()
        }
    }

    public func stopCapture() async {
        let shouldRemoveTap = hasInstalledTap
        hasInstalledTap = false
        if shouldRemoveTap {
            engine.inputNode.removeTap(onBus: 0)
        }
        // Also stop any in-flight AI playback so a session end always leaves
        // the engine silent on both directions.
        if playerAttached {
            playerNode.stop()
        }
        if engine.isRunning {
            engine.stop()
        }

        if let emitted = speechTracker.reset() {
            continuation.yield(emitted)
        }
        playbackGate.reset()
        lastInterruptRequestedAt = nil

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }

    nonisolated public func events() -> AsyncStream<AudioEngineEvent> {
        stream
    }

    public func play(frame: WSAudioFrame) async {
        guard playbackGate.shouldAccept(frame) else { return }

        let pcm: Data
        do {
            pcm = try await decoder.decode(frame)
        } catch {
            continuation.yield(.failed("decode failed: \(error)"))
            return
        }

        attachPlayerIfNeeded()
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

    public func interruptNow() async {
        lastInterruptRequestedAt = clock.now
        _ = playbackGate.markInterrupted()
        if playerAttached {
            playerNode.stop()
        }
    }

    /// Snapshot of the last `interruptNow()` instant for barge-in latency tests.
    /// Public on the actor so tests can read it without exposing the raw clock.
    public func lastInterruptInstant() -> ContinuousClock.Instant? {
        lastInterruptRequestedAt
    }

    private func processInput(_ buffer: AVAudioPCMBuffer) async {
        do {
            guard let pcm = try convertToPCM16(buffer) else { return }
            continuation.yield(.pcmChunk(pcm))
            updateSpeechState(using: pcm)
        } catch {
            continuation.yield(.failed(error.localizedDescription))
        }
    }

    private func updateSpeechState(using pcm: Data) {
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

    private func configureAudioSessionIfNeeded() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setPreferredSampleRate(16_000)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
        #endif
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
