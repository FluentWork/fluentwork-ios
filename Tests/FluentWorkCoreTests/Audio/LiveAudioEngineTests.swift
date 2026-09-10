import AVFoundation
import Dispatch
import FluentWorkNetworking
import Foundation
import Testing
@testable import FluentWorkCore

// MARK: - Decoder tests

@Test func rawPCM16FrameDecoderRoundtripPreservesBytes() async throws {
    let decoder = RawPCM16FrameDecoder()
    let payload = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
    let frame = WSAudioFrame(sequence: 1, opusPayload: payload)

    let decoded = try await decoder.decode(frame)

    #expect(decoded == payload)
}

@Test func rawPCM16FrameDecoderRejectsOddSampleCount() async {
    let decoder = RawPCM16FrameDecoder()
    let frame = WSAudioFrame(sequence: 1, opusPayload: Data([0x01, 0x02, 0x03]))

    await #expect(throws: RawPCM16FrameDecoder.Error.oddSampleCount(3)) {
        _ = try await decoder.decode(frame)
    }
}

@Test func volcengineOpusFrameDecoderReturnsNotAvailableUntilB13Lands() async {
    let decoder = VolcengineOpusFrameDecoder()
    let frame = WSAudioFrame(sequence: 1, opusPayload: Data([0x01, 0x02]))

    await #expect(throws: VolcengineOpusFrameDecoder.Error.notAvailable) {
        _ = try await decoder.decode(frame)
    }
}

// MARK: - Engine tests

@available(iOS 17, macOS 14, *)
@Test func liveAudioEnginePlayRoutesThroughDecoder() async {
    let log = CallLog()
    let decoder = CapturingFrameDecoder(log: log, samplesPerFrame: 4)
    let engine = LiveAudioEngine(decoder: decoder)

    await engine.play(frame: WSAudioFrame(sequence: 1, opusPayload: Data(repeating: 0x01, count: 8)))
    await engine.play(frame: WSAudioFrame(sequence: 2, opusPayload: Data(repeating: 0x02, count: 8)))

    let captured = await log.snapshot()
    #expect(captured.count == 2)
    #expect(captured.map(\.sequence) == [1, 2])
}

/// `scheduleBuffer` queues audio onto a player node, and a node that was never
/// started plays nothing. Nothing started it, so the assistant stayed silent
/// even after the gateway began forwarding its audio — and the decoder test
/// above passed the whole time, because it only asserts the decoder was
/// reached, never that anything came out.
@available(iOS 17, macOS 14, *)
@Test func liveAudioEngineStartsPlaybackForScheduledAudio() async {
    let decoder = CapturingFrameDecoder(log: CallLog(), samplesPerFrame: 4)
    let engine = LiveAudioEngine(decoder: decoder)

    #expect(await engine._testPlaybackStarted() == false)

    await engine.play(frame: WSAudioFrame(sequence: 1, opusPayload: Data(repeating: 0x01, count: 8)))

    #expect(await engine._testPlaybackStarted() == true)
}

/// `AVAudioPlayerNode.play()` on a stopped engine does not throw — it raises an
/// uncaught `NSException` ("player started when in a disconnected state") and
/// terminates the app. Nothing guarded the call: `try? engine.start()` swallowed
/// exactly the failure that leaves the engine stopped, so `play()` ran anyway.
@available(iOS 17, macOS 14, *)
@Test func liveAudioEngineDoesNotStartPlaybackOnAStoppedEngine() async {
    struct EngineRefusedToStart: Error {}
    let decoder = CapturingFrameDecoder(log: CallLog(), samplesPerFrame: 4)
    let engine = LiveAudioEngine(
        decoder: decoder,
        startEngineForPlayback: { _ in throw EngineRefusedToStart() }
    )
    let stream = engine.events()

    await engine.play(frame: WSAudioFrame(sequence: 1, opusPayload: Data(repeating: 0x01, count: 8)))

    #expect(await engine._testEngineRunning() == false)
    #expect(
        await engine._testPlaybackStarted() == false,
        "starting a node on a stopped engine is what raises 'player started when in a disconnected state'"
    )

    let failure = await consumeFirstEvent(stream, within: .milliseconds(250)) { event in
        if case .failed = event { return event } else { return nil }
    }
    guard case .failed = failure else {
        Issue.record("expected the dropped frame to surface as .failed, got \(String(describing: failure))")
        return
    }
}

/// `stopCapture()` runs on `endSession`, which tears down the engine the player
/// node is attached to — but the socket still holds assistant audio in flight,
/// and cancelling the transport task is not instant. Those frames must not reach
/// `play()`: with the node detached and the engine stopped, `play()` raises an
/// uncaught `NSException` ("player started when in a disconnected state") and
/// terminates the app. Capture and playback share one graph, so ending the
/// session has to retire both.
@available(iOS 17, macOS 14, *)
@Test func liveAudioEngineRetiresPlaybackWhenCaptureStops() async {
    let decoder = CapturingFrameDecoder(log: CallLog(), samplesPerFrame: 4)
    let engine = LiveAudioEngine(decoder: decoder)
    let stream = engine.events()

    // Live session: playback works.
    await engine.play(frame: WSAudioFrame(sequence: 1, opusPayload: Data(repeating: 0x01, count: 8)))
    #expect(await engine._testPlaybackStarted() == true)

    // Session ends; a frame that was already in flight arrives afterwards.
    await engine.stopCapture()
    await engine.play(frame: WSAudioFrame(sequence: 2, opusPayload: Data(repeating: 0x02, count: 8)))

    #expect(
        await engine._testPlaybackStarted() == false,
        "a frame that outlives its session must not start a node whose graph is gone"
    )

    let failure = await consumeFirstEvent(stream, within: .milliseconds(250)) { event in
        if case .failed = event { return event } else { return nil }
    }
    guard case .failed = failure else {
        Issue.record("expected the retired frame to surface as .failed, got \(String(describing: failure))")
        return
    }
}

/// `setSpeechBoundaryMode` owns the tracker's configuration, and `startCapture()`
/// runs immediately after it to begin the session. Rebuilding the tracker there
/// with a bare `AudioSpeechActivityTracker()` restored the auto-VAD defaults, so
/// every tap-to-start session silently ran with energy allowed to *open* a turn
/// and a 1.5s pause able to close one — the mode the session asked for never
/// reached the audio path at all.
@available(iOS 17, macOS 14, *)
@Test func liveAudioEngineStartCaptureKeepsTheConfiguredBoundaryMode() async {
    let engine = LiveAudioEngine(
        sessionManager: PermissiveAudioSessionManager(),
        decoder: RawPCM16FrameDecoder(),
        requestMicrophonePermission: { true }
    )

    await engine.setSpeechBoundaryMode(.tapToStart)
    _ = try? await engine.startCapture()

    let tracker = await engine._testSpeechTracker()
    #expect(
        tracker.autoStart == false,
        "tap-to-start must not let energy open a turn"
    )
    #expect(
        tracker.silenceHold == AudioSpeechActivityTracker.tapToStartSilenceHold,
        "startCapture rebuilt the tracker with the \(tracker.silenceHold) auto-VAD hold"
    )
}

@available(iOS 17, macOS 14, *)
@Test func liveAudioEngineStartCaptureFailsWhenPermissionDenied() async {
    let engine = LiveAudioEngine(
        decoder: RawPCM16FrameDecoder(),
        requestMicrophonePermission: { false }
    )

    await #expect(throws: AudioEnginePermissionError.microphoneDenied) {
        try await engine.startCapture()
    }
}

@available(iOS 17, macOS 14, *)
@Test func liveAudioEngineManualSpeechEmitsStartAndEnd() async {
    let engine = LiveAudioEngine(
        decoder: RawPCM16FrameDecoder(),
        requestMicrophonePermission: { true }
    )
    let stream = engine.events()

    await engine.beginManualSpeech()
    let started = await consumeFirstEvent(stream, within: .milliseconds(250)) { event in
        event == .speechStarted ? event : nil
    }
    #expect(started == .speechStarted)

    await engine.endManualSpeech()
    let ended = await consumeFirstEvent(stream, within: .milliseconds(250)) { event in
        event == .speechEnded ? event : nil
    }
    #expect(ended == .speechEnded)
}

@available(iOS 17, macOS 14, *)
@Test func liveAudioEngineManualSpeechStartIsIdempotent() async {
    let engine = LiveAudioEngine(
        decoder: RawPCM16FrameDecoder(),
        requestMicrophonePermission: { true }
    )
    await engine.beginManualSpeech()
    await engine.beginManualSpeech()
    let stream = engine.events()
    await engine.endManualSpeech()
    let ended = await consumeFirstEvent(stream, within: .milliseconds(250)) { event in
        event == .speechEnded ? event : nil
    }
    #expect(ended == .speechEnded)
}

@Test func speechActivityTrackerForceStartAndEndRoundTrip() {
    var tracker = AudioSpeechActivityTracker()
    #expect(tracker.forceStart() == .speechStarted)
    #expect(tracker.forceStart() == nil)
    #expect(tracker.forceEnd() == .speechEnded)
    #expect(tracker.forceEnd() == nil)
}

/// The boundary mode owns both the auto-start flag and the endpointing hold,
/// so a mode switch has to move them together. Tap-to-start in particular must
/// not inherit the auto-VAD hold, which submits a turn the moment the speaker
/// pauses to think.
@Test func liveAudioEngineSpeechBoundaryModeConfiguresTracker() async {
    let engine = LiveAudioEngine(
        sessionManager: ThrowingAudioSessionManager(),
        decoder: RawPCM16FrameDecoder(),
        requestMicrophonePermission: { true }
    )

    await engine.setSpeechBoundaryMode(.tapToStart)
    let tapToStart = await engine._testSpeechTracker()
    #expect(tapToStart.autoStart == false)
    #expect(tapToStart.silenceHold == AudioSpeechActivityTracker.tapToStartSilenceHold)

    await engine.setSpeechBoundaryMode(.autoVAD)
    let autoVAD = await engine._testSpeechTracker()
    #expect(autoVAD.autoStart == true)
    #expect(autoVAD.silenceHold == AudioSpeechActivityTracker.autoVADSilenceHold)

    // Legacy tap-to-talk consults neither energy flag.
    await engine.setSpeechBoundaryMode(.manual)
    let manual = await engine._testSpeechTracker()
    #expect(manual.autoStart == false)
}

@available(iOS 17, macOS 14, *)
@Test func liveAudioEngineStartCaptureConfiguresFullDuplexAndPropagatesSessionError() async {
    let sessionManager = ThrowingAudioSessionManager()
    let engine = LiveAudioEngine(
        sessionManager: sessionManager,
        decoder: RawPCM16FrameDecoder(),
        requestMicrophonePermission: { true }
    )

    await #expect(throws: ThrowingAudioSessionManager.Failure.expected) {
        try await engine.startCapture()
    }
    #expect(sessionManager.didConfigureFullDuplex)
}

@available(iOS 17, macOS 14, *)
@Test func liveAudioEnginePlaySurfacesDecodeFailureAsFailedEvent() async {
    let engine = LiveAudioEngine(decoder: ThrowingFrameDecoder())
    let stream = engine.events()

    await engine.play(frame: WSAudioFrame(sequence: 1, opusPayload: Data([0x01, 0x02])))

    // Drain up to 250 ms — long enough to surface the failure, short enough
    // to keep CI responsive if the engine never emits. The TaskGroup wrapper
    // cancels the stream iterator either way so the actor's deinit can fire
    // and `swift test` can exit cleanly.
    let failure = await consumeFirstEvent(stream, within: .milliseconds(250)) { event in
        if case .failed = event { return event } else { return nil }
    }

    guard case let .failed(message) = failure else {
        Issue.record("expected a .failed event from a throwing decoder, got \(String(describing: failure))")
        return
    }
    #expect(message.contains("decode failed"))
}

/// Consumes the first matching event from `stream` within `timeout`, cancelling
/// the stream iterator on either branch so the source actor can deinit.
private func consumeFirstEvent<T: Sendable>(
    _ stream: AsyncStream<AudioEngineEvent>,
    within timeout: Duration,
    selector: @escaping @Sendable (AudioEngineEvent) -> T?
) async -> T? {
    await withTaskGroup(of: T?.self, returning: T?.self.self) { group in
        group.addTask {
            for await event in stream {
                if let match = selector(event) {
                    return match
                }
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        for await result in group {
            group.cancelAll()
            return result
        }
        return nil
    }
}

@available(iOS 17, macOS 14, *)
@Test func liveAudioEngineInterruptRecordsTimestampWithinLatencyBudget() async {
    let engine = LiveAudioEngine(decoder: RawPCM16FrameDecoder())

    let before = ContinuousClock.now
    await engine.interruptNow()
    let recorded = await engine.lastInterruptInstant()

    #expect(recorded != nil, "interruptNow should record a barge-in instant")
    let instant = recorded ?? before
    let latency = ContinuousClock.now - instant
    #expect(latency <= .milliseconds(200), "engine should surface interrupt timestamp inside the 200 ms barge-in budget")
}

@available(iOS 17, macOS 14, *)
@Test func liveAudioEngineTapChainProduces16kMonoPCM16() async throws {
    // Simulate a 44.1 kHz stereo float32 input the way the iOS input tap would
    // hand it off; the converter should downmix + resample to the
    // Volcengine-aligned 16 kHz mono PCM16 target shape.
    let sourceSampleRate: Double = 44_100
    let sourceChannels: AVAudioChannelCount = 2
    let frameCount: AVAudioFrameCount = 4_410

    guard let sourceFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sourceSampleRate,
        channels: sourceChannels,
        interleaved: false
    ) else {
        Issue.record("source format unavailable")
        return
    }

    guard let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
        Issue.record("input buffer unavailable")
        return
    }
    input.frameLength = frameCount

    // Fill both channels with the same ramp so downmixing is observable.
    if let left = input.floatChannelData?[0], let right = input.floatChannelData?[1] {
        for index in 0 ..< Int(frameCount) {
            let ramp = Float(index) / Float(frameCount)
            left[index] = ramp
            right[index] = ramp
        }
    }

    let engine = LiveAudioEngine(decoder: RawPCM16FrameDecoder())
    let pcm = try #require(
        try engine._testConvertToPCM16(input, from: sourceFormat),
        "tap chain should produce PCM16 bytes"
    )

    // Volcengine aligned target: 16 kHz, mono, interleaved PCM16 — bytes are
    // Int16 little-endian, so the payload length must be a multiple of 2.
    // We assert within ±10 % of the naive ratio because `AVAudioConverter`'s
    // internal resampler is allowed to drift a handful of samples per buffer;
    // measured drift on a 4_410-frame 44.1 kHz → 16 kHz conversion lands near
    // 7.5 % (1480 vs 1600 expected), so 5 % is too tight for this buffer size.
    let expectedSampleCount = Int(Double(frameCount) * 16_000.0 / sourceSampleRate)
    let actualSampleCount = pcm.count / 2
    let drift = Double(abs(actualSampleCount - expectedSampleCount)) / Double(expectedSampleCount)
    #expect(drift < 0.10, "tap chain samples \(actualSampleCount) drifted \(drift) from expected \(expectedSampleCount)")

    let samples = pcm.withUnsafeBytes { raw -> [Int16] in
        let bound = raw.bindMemory(to: Int16.self)
        return Array(bound)
    }
    #expect(!samples.isEmpty)
    let mean = samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count)
    #expect(abs(mean) > 1, "tap chain output should preserve non-zero energy after downmix")
}

@available(iOS 17, macOS 14, *)
@Test func liveAudioEnginePlaySkipsFramesAtOrBelowInterruptWatermark() async {
    let log = CallLog()
    let decoder = CapturingFrameDecoder(log: log, samplesPerFrame: 4)
    let engine = LiveAudioEngine(decoder: decoder)

    // Pre-interrupt frame — gate accepts, decoder runs.
    await engine.play(frame: WSAudioFrame(sequence: 10, opusPayload: Data(repeating: 0x01, count: 8)))
    // Bump the watermark to 10.
    await engine.interruptNow()
    // Same sequence after interrupt — gate rejects (10 <= 10).
    await engine.play(frame: WSAudioFrame(sequence: 10, opusPayload: Data(repeating: 0x02, count: 8)))
    // Fresh sequence past the watermark — gate accepts again.
    await engine.play(frame: WSAudioFrame(sequence: 11, opusPayload: Data(repeating: 0x03, count: 8)))

    let captured = await log.snapshot()
    #expect(captured.count == 2, "expected 1 pre-interrupt + 1 post-watermark frame; got \(captured.count)")
    #expect(captured.map(\.sequence) == [10, 11])
}

@available(iOS 17, macOS 14, *)
@Test func liveAudioEngineStartAndStopInterruptionObservationRecordsCalls() async {
    let observer = RecordingAudioInterruptionObserver()
    let engine = LiveAudioEngine(
        decoder: RawPCM16FrameDecoder(),
        interruptionObserver: observer
    )

    await engine.startInterruptionObservation()
    #expect(observer.startCount == 1)

    await engine.stopInterruptionObservation()
    #expect(observer.stopCount == 1)
}

@available(iOS 17, macOS 14, *)
@Test func liveAudioEngineHandleBeganYieldsInterruptedBySystemWithoutStartCapture() async {
    let engine = LiveAudioEngine(
        decoder: RawPCM16FrameDecoder(),
        interruptionObserver: RecordingAudioInterruptionObserver()
    )
    let stream = engine.events()

    await engine.handleInterruption(.began)

    let event = await consumeFirstEvent(stream, within: .milliseconds(250)) { event in
        if case .interruptedBySystem = event { return event } else { return nil }
    }
    #expect(event == .interruptedBySystem)
}

@available(iOS 17, macOS 14, *)
@Test func liveAudioEngineHandleRouteChangedYieldsFailedRouteChanged() async {
    let engine = LiveAudioEngine(
        decoder: RawPCM16FrameDecoder(),
        interruptionObserver: RecordingAudioInterruptionObserver()
    )
    let stream = engine.events()

    await engine.handleInterruption(.routeChanged(reason: "oldDeviceUnavailable"))

    let event = await consumeFirstEvent(stream, within: .milliseconds(250)) { event in
        if case .routeChanged = event { return event } else { return nil }
    }
    #expect(event == .routeChanged("oldDeviceUnavailable"))

    await engine.reconfigureForRouteChange()
}

@available(iOS 17, macOS 14, *)
@Test func liveAudioEngineHandleEndedShouldResumeFalseDoesNotYieldSystemInterruptEnded() async {
    let engine = LiveAudioEngine(
        decoder: RawPCM16FrameDecoder(),
        interruptionObserver: RecordingAudioInterruptionObserver()
    )
    let stream = engine.events()

    await engine.handleInterruption(.ended(shouldResume: false))

    let event = await consumeFirstEvent(stream, within: .milliseconds(250)) { event in
        if case .systemInterruptEnded = event { return event } else { return nil }
    }
    #expect(event == nil)
}

@available(iOS 17, macOS 14, *)
@Test func liveAudioEngineHandleEndedShouldResumeTrueAfterBeganYieldsSystemInterruptEnded() async {
    let engine = LiveAudioEngine(
        decoder: RawPCM16FrameDecoder(),
        interruptionObserver: RecordingAudioInterruptionObserver()
    )
    let stream = engine.events()

    await engine.handleInterruption(.began)
    await engine.handleInterruption(.ended(shouldResume: true))

    let event = await consumeFirstEvent(stream, within: .milliseconds(250)) { event in
        if case .systemInterruptEnded = event { return event } else { return nil }
    }
    #expect(event == .systemInterruptEnded)
}

// MARK: - Test doubles

actor CallLog {
    private(set) var frames: [WSAudioFrame] = []
    func append(_ frame: WSAudioFrame) { frames.append(frame) }
    func snapshot() -> [WSAudioFrame] { frames }
}

actor CapturingFrameDecoder: WSAudioFrameDecoder {
    private let log: CallLog
    private let samplesPerFrame: Int

    init(log: CallLog, samplesPerFrame: Int) {
        self.log = log
        self.samplesPerFrame = samplesPerFrame
    }

    func decode(_ frame: WSAudioFrame) async throws -> Data {
        await log.append(frame)
        let byteCount = samplesPerFrame * 2
        return Data(repeating: 0, count: byteCount)
    }
}

struct ThrowingFrameDecoder: WSAudioFrameDecoder {
    enum Failure: Error, Equatable { case boom }
    func decode(_ frame: WSAudioFrame) async throws -> Data {
        throw Failure.boom
    }
}

final class ThrowingAudioSessionManager: AudioSessionManaging, @unchecked Sendable {
    enum Failure: Error, Equatable {
        case expected
    }

    private let queue = DispatchQueue(label: "com.fluentwork.tests.throwing-audio-session")
    private var configuredRoute: AudioRoute?

    func configure(for route: AudioRoute) throws {
        queue.sync {
            configuredRoute = route
        }
        throw Failure.expected
    }

    func pause() throws {}
    func resume() throws {}

    var isActive: Bool {
        get async { false }
    }

    var didConfigureFullDuplex: Bool {
        queue.sync {
            guard case .fullDuplex = configuredRoute else { return false }
            return true
        }
    }
}

/// Accepts configuration so a test can drive `startCapture()` past the audio
/// session and reach the state it sets up. `ThrowingAudioSessionManager` bails
/// out at `configure`, which is before the engine touches any of that.
final class PermissiveAudioSessionManager: AudioSessionManaging, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.fluentwork.tests.permissive-audio-session")
    private var configuredRoute: AudioRoute?

    func configure(for route: AudioRoute) throws {
        queue.sync { configuredRoute = route }
    }

    func pause() throws {}
    func resume() throws {}

    var isActive: Bool {
        get async { true }
    }

    var didConfigureFullDuplex: Bool {
        queue.sync {
            guard case .fullDuplex = configuredRoute else { return false }
            return true
        }
    }
}

final class RecordingAudioInterruptionObserver: AudioInterruptionObserving, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.fluentwork.tests.recording-audio-interruption")
    private var starts = 0
    private var stops = 0

    func start(_ onEvent: @escaping @Sendable (AudioInterruptionKind) async -> Void) {
        queue.sync {
            starts += 1
            _ = onEvent
        }
    }

    func stop() {
        queue.sync {
            stops += 1
        }
    }

    var startCount: Int {
        queue.sync { starts }
    }

    var stopCount: Int {
        queue.sync { stops }
    }
}
