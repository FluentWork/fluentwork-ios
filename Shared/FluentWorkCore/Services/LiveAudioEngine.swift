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
    private let targetFormat = AVAudioFormat(
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

    public init() {
        let pair = AsyncStream.makeStream(
            of: AudioEngineEvent.self,
            bufferingPolicy: .bufferingNewest(64)
        )
        self.stream = pair.stream
        self.continuation = pair.continuation
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
        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
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
        if engine.isRunning {
            engine.stop()
        }

        if let emitted = speechTracker.reset() {
            continuation.yield(emitted)
        }
        playbackGate.reset()

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }

    nonisolated public func events() -> AsyncStream<AudioEngineEvent> {
        stream
    }

    public func play(frame: WSAudioFrame) async {
        guard playbackGate.shouldAccept(frame) else { return }
        // Decoder / player-node scheduling will hang off this gate next.
    }

    public func interruptNow() async {
        _ = playbackGate.markInterrupted()
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

        let ratio = targetFormat.sampleRate / max(sourceFormat.sampleRate, 1)
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
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
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setPreferredSampleRate(16_000)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
        #endif
    }
}
