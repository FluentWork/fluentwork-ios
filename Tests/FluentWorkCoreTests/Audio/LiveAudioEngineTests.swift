import AVFoundation
import Dispatch
import FluentWorkNetworking
import FluentWorkObjCSupport
import Foundation
import Testing
@testable import FluentWorkCore

// MARK: - Objective-C exception bridge

/// The backstop under `AVAudioPlayerNode.play()`.
///
/// `play()` raises rather than returning an error when the node has nothing to
/// play into. Three device builds died on exactly that, at the same place, with
/// the same message — so the playback path now depends on being able to catch
/// it rather than on predicting it. This test is that dependency: if the bridge
/// stops catching, nothing in the playback path can be trusted.
@Test func objcExceptionCatcherTurnsARaiseIntoAnError() {
    var raised: NSError?
    let completed = FWTryCatch(
        { NSException(name: .genericException, reason: "boom", userInfo: nil).raise() },
        &raised
    )

    #expect(completed == false)
    #expect(raised?.localizedDescription == "boom")
    #expect(raised?.userInfo["FWExceptionName"] as? String == NSExceptionName.genericException.rawValue)
}

@Test func objcExceptionCatcherReportsSuccessWhenNothingRaises() {
    var raised: NSError?
    var ran = false
    let completed = FWTryCatch({ ran = true }, &raised)

    #expect(completed == true)
    #expect(ran)
    #expect(raised == nil)
}

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
/// `playerNode.play()`: with the node detached and the engine stopped, `play()`
/// raises an uncaught `NSException` ("player started when in a disconnected
/// state") and terminates the app. Capture and playback share one graph, so
/// ending the session has to retire both.
///
/// The retired frame is dropped, not surfaced as `.failed`. The audio pump
/// treats `.failed` as fatal (`docs/49`); see
/// `stopCaptureDropsLateFramesWithoutFailingTheEngine`.
@available(iOS 17, macOS 14, *)
@Test func liveAudioEngineRetiresPlaybackWhenCaptureStops() async {
    let decoder = CapturingFrameDecoder(log: CallLog(), samplesPerFrame: 4)
    let engine = LiveAudioEngine(decoder: decoder)

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

/// Every path that closes an utterance has to report how it closed — a path
/// that emitted its boundary directly would contribute nothing to the
/// distribution, and the missing data would look like a quiet week rather than
/// like a bug.
///
/// This is the tap path, which is reachable hermetically; the energy path uses
/// the same `yieldSpeechBoundary`, and the tracker half is pinned separately in
/// `FoundationComponentsTests`.
@available(iOS 17, macOS 14, *)
@Test func endingAManualTurnReportsHowItClosed() async {
    let engine = LiveAudioEngine(decoder: RawPCM16FrameDecoder())
    let stream = engine.events()

    await engine.beginManualSpeech()
    await engine.endManualSpeech()

    let endpointed = await consumeFirstEvent(stream, within: .milliseconds(250)) { event in
        if case .speechEndpointed = event { return event } else { return nil }
    }
    guard case let .speechEndpointed(reason, windowMs, trailingSilenceMs) = endpointed else {
        Issue.record("expected a .speechEndpointed, got \(String(describing: endpointed))")
        return
    }
    #expect(reason == "manual")
    #expect(trailingSilenceMs == nil, "a tap has no trailing silence — and nil is not zero")
    #expect(windowMs != nil, "the window is measured by the engine, which is the only party holding a clock")
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

// MARK: - Engine-level voice processing (AEC)

/// A multi-channel format of the shape voice processing hands back.
///
/// Not `AVAudioFormat(commonFormat:sampleRate:channels:interleaved:)` — that
/// initializer only builds a layout for one and two channels and returns `nil`
/// above that, while voice processing returns more (reports of 3, 7 and 9). A
/// *discrete* layout is how you say "N channels, no implied speaker positions",
/// which is exactly what the echo-reference channels are.
private func makeDiscreteFormat(channels: AVAudioChannelCount) -> AVAudioFormat? {
    guard let layout = AVAudioChannelLayout(
        layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels
    ) else {
        return nil
    }
    return AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        interleaved: false,
        channelLayout: layout
    )
}

/// Enabling voice processing is what changes the input node's shape, so the
/// tap has to be installed with the node's *output* format rather than the raw
/// input format the chain used before.
///
/// Getting the choice wrong does not throw. The stale format is still valid,
/// the converter still builds, the tap still installs — and then every buffer
/// is dropped at `processInput`'s guard. Capture that looks alive and carries
/// nothing is the failure this pin exists for.
@available(iOS 17, macOS 14, *)
@Test func captureFormatUsesTheProcessedStreamOnlyWhenVoiceProcessingIsOn() throws {
    let raw = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    ))
    let processed = try #require(makeDiscreteFormat(channels: 3))

    // Off: exactly the format the chain used before — the fallback path has to
    // stay byte for byte what it was.
    #expect(
        LiveAudioEngine.captureFormat(
            input: raw,
            processedOutput: processed,
            voiceProcessingActive: false
        )?.channelCount == 1
    )
    // On: the unit sits between the node's input and output, so the processed
    // stream is what the tap receives.
    #expect(
        LiveAudioEngine.captureFormat(
            input: raw,
            processedOutput: processed,
            voiceProcessingActive: true
        )?.channelCount == 3
    )
}

/// With the unit engaged there is **no** fallback to the raw format, and this
/// pin is what keeps a well-meaning `?? usable(input)` from coming back.
///
/// While the unit is on the node produces the processed stream, so the raw
/// input format describes a stream that is no longer there. Falling back would
/// install a tap the node cannot satisfy — the documented `CreateRecordingTap`
/// abort — and the report would still say `on`, because the unit really is on.
/// A dead chain logged as a healthy one is worse than a refused session.
@available(iOS 17, macOS 14, *)
@Test func captureFormatRefusesRatherThanFallingBackToTheRawInputWhileVoiceProcessingIsOn() throws {
    let raw = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 44_100,
        channels: 1,
        interleaved: false
    ))

    #expect(
        LiveAudioEngine.captureFormat(
            input: raw,
            processedOutput: nil,
            voiceProcessingActive: true
        ) == nil,
        "the raw format is not the node's stream while the unit is on"
    )
    // Off is the other half, and it is unchanged: the raw format, exactly as
    // the chain worked before this feature existed.
    #expect(
        LiveAudioEngine.captureFormat(
            input: raw,
            processedOutput: nil,
            voiceProcessingActive: false
        )?.sampleRate == 44_100
    )
    // Nothing usable on either side is still `nil` — the caller turns that into
    // the recoverable `invalidFormat`, as it always did.
    #expect(LiveAudioEngine.captureFormat(input: nil, processedOutput: nil, voiceProcessingActive: true) == nil)
    #expect(LiveAudioEngine.captureFormat(input: nil, processedOutput: nil, voiceProcessingActive: false) == nil)
}

/// Voice processing does not hand back a cleaned copy of the microphone — it
/// hands back the microphone channel *plus* the channels the echo canceller
/// needs, and only channel 0 is the speaker.
@available(iOS 17, macOS 14, *)
@Test func captureChannelMapTakesOnlyTheMicrophoneChannel() throws {
    let target = try #require(AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    ))

    let multi = try #require(makeDiscreteFormat(channels: 3))
    let multiConverter = try #require(AVAudioConverter(from: multi, to: target))

    // The thing worth pinning is what the default *is*, because it is not the
    // downmix you would assume. A discrete multi-channel layout implies no
    // mapping onto a single channel, so the converter reports `-1` — which the
    // API defines as "this output channel gets no input at all". The uplink
    // would not be noisy; it would be empty, from a chain that looks perfectly
    // healthy. Measured, not assumed.
    #expect(
        multiConverter.channelMap.map(\.intValue) == [-1],
        "a discrete multi-channel input maps to silence by default — that is the failure this fixes"
    )

    LiveAudioEngine.applyCaptureChannelMap(multiConverter, from: multi)
    #expect(multiConverter.channelMap.map(\.intValue) == [0], "channel 0 is the microphone")

    // Single channel is the pre-voice-processing shape, and its default is
    // already correct. Mapping it would be a change to the fallback chain that
    // nothing asked for.
    let mono = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 44_100,
        channels: 1,
        interleaved: false
    ))
    let monoConverter = try #require(AVAudioConverter(from: mono, to: target))
    LiveAudioEngine.applyCaptureChannelMap(monoConverter, from: mono)
    #expect(monoConverter.channelMap.map(\.intValue) == [0], "the single-channel chain keeps its mapping")
}

/// The same finding, run through the tap chain instead of asserted on the
/// helper — because "the mapping is `[0]`" and "a voice comes out the other
/// end" are two different claims, and only the second one is the product.
///
/// It also closes the gap that let the hook go stale: `_testConvertToPCM16`
/// now applies the same map production does, so this is the tap chain as it
/// actually is, not a simplified stand-in.
@available(iOS 17, macOS 14, *)
@Test func multiChannelInputReachesTheTapChainAsAudioNotSilence() throws {
    let source = try #require(makeDiscreteFormat(channels: 3))
    let frames: AVAudioFrameCount = 4_800
    let input = try #require(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames))
    input.frameLength = frames

    // Channel 0 is the microphone; the rest are the echo canceller's. Constant
    // amplitude, so "did anything arrive" is a magnitude question rather than a
    // shape one.
    for channel in 0 ..< Int(source.channelCount) {
        let samples = try #require(input.floatChannelData?[channel])
        for index in 0 ..< Int(frames) {
            samples[index] = channel == 0 ? 0.5 : 0
        }
    }

    let engine = LiveAudioEngine(decoder: RawPCM16FrameDecoder())
    let pcm = try #require(
        try engine._testConvertToPCM16(input, from: source),
        "the tap chain should produce PCM16 bytes"
    )
    let samples = pcm.withUnsafeBytes { raw -> [Int16] in
        Array(raw.bindMemory(to: Int16.self))
    }
    #expect(!samples.isEmpty)
    let peak = samples.map { abs(Int($0)) }.max() ?? 0
    #expect(
        peak > 1_000,
        "channel 0 carries the microphone; a chain that drops it produces silence, not a quieter voice"
    )
}

/// The enable has to run before the input format is read. Enabling is what
/// changes the node's shape, so a caller that reads first and enables second
/// builds its converter and its tap against a stream that no longer exists.
///
/// It runs *before* the format guard, and that is what makes it observable:
/// CI has no audio input device, so `startCapture()` stops at the guard on
/// every run and nothing after it executes. Asserting on what happened before
/// the throw is the same shape as asserting `didConfigureFullDuplex` while the
/// session manager is throwing — and it is honest about its limit, which is
/// that the guard is where this test's reach ends.
@available(iOS 17, macOS 14, *)
@Test func startCaptureEnablesVoiceProcessingBeforeReadingTheInputFormat() async {
    let recorder = VoiceProcessingRecorder()
    let engine = LiveAudioEngine(
        sessionManager: PermissiveAudioSessionManager(),
        decoder: RawPCM16FrameDecoder(),
        requestMicrophonePermission: { true },
        applyVoiceProcessing: { try recorder.record($0) }
    )

    await engine.setVoiceProcessingEnabled(true)
    _ = try? await engine.startCapture()

    #expect(
        recorder.calls == 1,
        "the enable runs before the format guard, so it is reached on a machine with no audio input"
    )
}

/// The report is the only thing a device run has to go on, so what it says has
/// to be the node's actual state rather than the session's intent.
///
/// "The call returned without throwing" is not the same fact as "the unit is
/// engaged" — enabling is automatic across both I/O nodes and can already be
/// on, so a build that asked and got nothing back would otherwise log a clean
/// `on` while running without echo cancellation at all.
@available(iOS 17, macOS 14, *)
@Test func voiceProcessingReportStatesTheNodeNotTheRequest() throws {
    let format = try #require(makeDiscreteFormat(channels: 1))

    // Turned on by this call.
    #expect(
        LiveAudioEngine.voiceProcessingReport(
            requested: true, isOn: true, wasAlreadyOn: false, skipReason: nil, format: format, failure: nil
        ) == "on, tap=48000Hz/1ch"
    )
    // Already on before the session asked — a different story, and one a
    // device log needs to be able to tell apart from the line above.
    #expect(
        LiveAudioEngine.voiceProcessingReport(
            requested: true, isOn: true, wasAlreadyOn: true, skipReason: nil, format: format, failure: nil
        ) == "on, alreadyOn, tap=48000Hz/1ch"
    )
    // The silent no-op: the call was clean and the unit is off anyway.
    #expect(
        LiveAudioEngine.voiceProcessingReport(
            requested: true, isOn: false, wasAlreadyOn: false, skipReason: nil, format: format, failure: nil
        ) == "off, tap=48000Hz/1ch"
    )
    // A refusal says so instead of reporting a state it does not have.
    #expect(
        LiveAudioEngine.voiceProcessingReport(
            requested: true, isOn: false, wasAlreadyOn: false, skipReason: nil, format: format, failure: "boom"
        ) == "unavailable: boom"
    )
}

/// The one line that must never read as a plain `off`.
///
/// When the session asked for the unit and this path could not toggle it, the
/// node being off is not the same fact as the flag being off. Reported as
/// `off` it is byte-identical to a build with the flag off — and the device
/// procedure's rule is "not `on`, don't judge yet", which would send the tester
/// off to patch `firstWave` and rebuild while the real cause was a running
/// engine. The A/B would quietly become "AEC off vs AEC off".
@available(iOS 17, macOS 14, *)
@Test func voiceProcessingReportDistinguishesAskedAndSkippedFromSimplyOff() throws {
    let format = try #require(makeDiscreteFormat(channels: 1))

    let skipped = LiveAudioEngine.voiceProcessingReport(
        requested: true,
        isOn: false,
        wasAlreadyOn: false,
        skipReason: "engine already running",
        format: format,
        failure: nil
    )
    #expect(skipped.contains("requested-but-not-applied"))
    #expect(skipped.contains("engine already running"))

    // The flag simply being off is the other state, and stays terse.
    #expect(
        LiveAudioEngine.voiceProcessingReport(
            requested: false, isOn: false, wasAlreadyOn: false, skipReason: nil, format: format, failure: nil
        ) == "off, tap=48000Hz/1ch"
    )
    // Skipping is only worth shouting about when it left the unit off. Had it
    // already been on, the skip cost nothing and `alreadyOn` is the story.
    #expect(
        LiveAudioEngine.voiceProcessingReport(
            requested: true, isOn: true, wasAlreadyOn: true, skipReason: "route change", format: format, failure: nil
        ) == "on, alreadyOn, tap=48000Hz/1ch"
    )
}

/// Opt-in, and the default build must not touch the node. Voice processing
/// changes the input format and pulls the output node into voice-processing
/// mode; a session that never asked for it should not get either.
@available(iOS 17, macOS 14, *)
@Test func startCaptureLeavesVoiceProcessingAloneUnlessTheSessionAskedForIt() async {
    let recorder = VoiceProcessingRecorder()
    let engine = LiveAudioEngine(
        sessionManager: PermissiveAudioSessionManager(),
        decoder: RawPCM16FrameDecoder(),
        requestMicrophonePermission: { true },
        applyVoiceProcessing: { try recorder.record($0) }
    )

    _ = try? await engine.startCapture()

    #expect(recorder.calls == 0, "voice processing is opt-in; the default session must not enable it")
}

/// Losing echo cancellation is bad; losing the microphone is worse. A device
/// that refuses the unit still captures, and the refusal is reported rather
/// than thrown.
///
/// What this can and cannot prove: it pins that the seam's own error is never
/// what `startCapture()` fails with. It cannot pin the *report*, because on a
/// machine with no audio input the format guard throws first — the same guard
/// that limits the ordering test above.
@available(iOS 17, macOS 14, *)
@Test func aRefusedVoiceProcessingUnitDoesNotFailTheSession() async {
    let recorder = VoiceProcessingRecorder()
    recorder.refuseNextCall()
    let engine = LiveAudioEngine(
        sessionManager: PermissiveAudioSessionManager(),
        decoder: RawPCM16FrameDecoder(),
        requestMicrophonePermission: { true },
        applyVoiceProcessing: { try recorder.record($0) }
    )

    await engine.setVoiceProcessingEnabled(true)
    var thrown: Error?
    do {
        try await engine.startCapture()
    } catch {
        thrown = error
    }

    #expect(
        !(thrown is VoiceProcessingRecorder.Refused),
        "a refused unit is a degraded session, not a failed one"
    )
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

/// An interruption that iOS will not let us resume has to end the run, not
/// strand it.
///
/// `.began` puts the machine into its suspended phase, and a suspended machine
/// **drops every event except five**. Emitting nothing when `shouldResume` is
/// false left nothing that could lift that suspension: playback stopped, the
/// UI kept showing the phase it was in, and every later audio event was
/// discarded — no error, no affordance, no way to tell what happened. The user
/// sees "the sound just stopped and the screen is stuck", which is exactly the
/// report this covers.
@available(iOS 17, macOS 14, *)
@Test func liveAudioEngineReportsAnInterruptionItCannotResume() async {
    let engine = LiveAudioEngine(
        decoder: RawPCM16FrameDecoder(),
        interruptionObserver: RecordingAudioInterruptionObserver()
    )
    let stream = engine.events()

    await engine.handleInterruption(.began)
    await engine.handleInterruption(.ended(shouldResume: false))

    let failure = await consumeFirstEvent(stream, within: .milliseconds(250)) { event in
        if case .failed = event { return event } else { return nil }
    }
    guard case .failed = failure else {
        Issue.record(
            "an interruption iOS will not resume must surface as .failed or the session hangs suspended; got \(String(describing: failure))"
        )
        return
    }
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

/// Records the injectable engine-level voice-processing seam.
///
/// Synchronous on purpose: the call it stands in for happens while the audio
/// graph is being built, so a recorder that needed an `await` could not model
/// it — the real one has to return before the input format is read. Queue
/// serialized in the same style as `ThrowingAudioSessionManager`.
final class VoiceProcessingRecorder: @unchecked Sendable {
    /// Stands in for a device that will not hand its audio route to the
    /// voice-processing unit.
    enum Refused: Error, Equatable { case refused }

    private let queue = DispatchQueue(label: "com.fluentwork.tests.voice-processing")
    private var recordedCalls = 0
    private var refuses = false
    /// What the node reports back after a call that did *not* throw. Separate
    /// from "the call succeeded" so a test can model the case the read-back
    /// exists for: the call returns cleanly and the unit is still not on.
    private var reportsEnabled = true

    func refuseNextCall() {
        queue.sync { refuses = true }
    }

    func record(_ inputNode: AVAudioInputNode) throws -> Bool {
        let outcome = queue.sync { () -> (refuse: Bool, enabled: Bool) in
            recordedCalls += 1
            return (refuses, reportsEnabled)
        }
        if outcome.refuse { throw Refused.refused }
        return outcome.enabled
    }

    var calls: Int {
        queue.sync { recordedCalls }
    }
}

// MARK: - Teardown order

/// **The rule: the graph may not be mutated while the engine is running.**
///
/// `engine.detach(_:)` and `inputNode.removeTap` both rearrange a live render
/// graph. Rearranging an `AVAudioEngine` underneath a running engine is the
/// F14/F15 family — this repository has paid for it three times, and its own
/// conclusion was "build the whole graph before `engine.start()`, do not move
/// it afterwards". `detach` raises an `NSException` rather than returning an
/// error, so getting this wrong ends the process. `removeTap` on a running
/// engine is the quieter cousin: it does not crash, it leaves a burst of
/// static in the speaker.
///
/// The user-visible symptom that started this: tapping 结束练习 *while TTS is
/// still playing* left a hiss after the confirmation. Stopping the player
/// without `reset()` also leaves scheduled PCM to drain through `engine.stop()`,
/// which is the same hiss from the other end. Until `PlaybackTeardown` existed
/// the order lived inside an actor that CI cannot drive — so nothing could
/// assert anything about it.
@Test func teardownNeverMutatesTheGraphWhileTheEngineIsRunning() {
    // The 结束练习-during-TTS path: capture tap is in, player has buffers queued,
    // engine is running. All three have to come apart, and in this order.
    let steps = PlaybackTeardown.steps(
        playerAttached: true,
        engineRunning: true,
        tapInstalled: true
    )

    #expect(
        steps == [.stopPlayer, .resetPlayer, .stopEngine, .removeTap, .detachPlayer],
        "got \(steps)"
    )

    let stopEngine = steps.firstIndex(of: .stopEngine)
    let detachPlayer = steps.firstIndex(of: .detachPlayer)
    let removeTap = steps.firstIndex(of: .removeTap)
    let resetPlayer = steps.firstIndex(of: .resetPlayer)

    #expect(detachPlayer != nil, "the node has to be detached, or the next session re-attaches against a torn-down graph")
    #expect(removeTap != nil, "an installed tap is a graph mutation, same family as detach")
    #expect(resetPlayer != nil, "stop() without reset() leaves scheduled PCM to drain as static")
    if let stopEngine, let detachPlayer {
        #expect(
            stopEngine < detachPlayer,
            """
            the engine must be stopped before the player is detached, or the graph \
            is rearranged underneath a running engine. Got \(steps).
            """
        )
    }
    if let stopEngine, let removeTap {
        #expect(
            stopEngine < removeTap,
            """
            the engine must be stopped before the tap is removed, or the graph \
            is rearranged underneath a running engine. Got \(steps).
            """
        )
    }
    if let resetPlayer, let stopPlayer = steps.firstIndex(of: .stopPlayer) {
        #expect(
            stopPlayer < resetPlayer,
            "reset dumps the queue; it has to follow stop so a playing node is not reset mid-render"
        )
    }
    if let resetPlayer, let stopEngine {
        #expect(
            resetPlayer < stopEngine,
            "the player is emptied before the engine stops, so no partial buffer is left to drain"
        )
    }
}

/// Nothing to detach, nothing to stop the player for — but a running engine is
/// still a running engine, and leaving it that way is what makes the next
/// session build its graph against a stale one.
@Test func teardownStopsARunningEngineEvenWithNoPlayer() {
    #expect(
        PlaybackTeardown.steps(playerAttached: false, engineRunning: true, tapInstalled: false) == [.stopEngine]
    )
    #expect(
        PlaybackTeardown.steps(playerAttached: true, engineRunning: false, tapInstalled: false)
            == [.stopPlayer, .resetPlayer, .detachPlayer]
    )
    #expect(
        PlaybackTeardown.steps(playerAttached: false, engineRunning: false, tapInstalled: false).isEmpty
    )
    #expect(
        PlaybackTeardown.steps(playerAttached: false, engineRunning: true, tapInstalled: true)
            == [.stopEngine, .removeTap]
    )
}

/// `stopCapture()` retires playback so leftover TTS frames from a socket that
/// has not closed yet have nowhere to go. Yielding `.failed` for those frames
/// is the wrong signal: the audio pump treats `.failed` as fatal and exits
/// for the rest of the process (`docs/49`), so "ended while the assistant was
/// still speaking" used to kill 「开始说话」 on the next session.
@available(iOS 17, macOS 14, *)
@Test func stopCaptureDropsLateFramesWithoutFailingTheEngine() async {
    let log = CallLog()
    let decoder = CapturingFrameDecoder(log: log, samplesPerFrame: 4)
    let engine = LiveAudioEngine(decoder: decoder)
    let stream = engine.events()

    await engine.play(frame: WSAudioFrame(sequence: 1, opusPayload: Data(repeating: 0x01, count: 8)))
    await engine.stopCapture()
    await engine.play(frame: WSAudioFrame(sequence: 2, opusPayload: Data(repeating: 0x02, count: 8)))

    let captured = await log.snapshot()
    #expect(captured.map(\.sequence) == [1], "late frames after stopCapture must not reach the decoder; got \(captured.map(\.sequence))")

    let failure = await consumeFirstEvent(stream, within: .milliseconds(250)) { event in
        if case .failed = event { return event } else { return nil }
    }
    #expect(failure == nil, "dropping a late frame must not fail the engine; got \(String(describing: failure))")
}

/// 结束练习弹窗打开时只 pause，不 teardown。迟到帧仍可进解码器（取消要接着播），
/// 但不得把 player 重新 play() 起来。确定之后才走 stopCapture。
@available(iOS 17, macOS 14, *)
@Test func pausePlaybackHoldsThePlayerWithoutRetiringIt() async {
    let log = CallLog()
    let decoder = CapturingFrameDecoder(log: log, samplesPerFrame: 4)
    let engine = LiveAudioEngine(decoder: decoder)
    let stream = engine.events()

    await engine.play(frame: WSAudioFrame(sequence: 1, opusPayload: Data(repeating: 0x01, count: 8)))
    await engine.pausePlayback()
    #expect(await engine.isPlaybackPaused())

    await engine.play(frame: WSAudioFrame(sequence: 2, opusPayload: Data(repeating: 0x02, count: 8)))
    let captured = await log.snapshot()
    #expect(captured.map(\.sequence) == [1, 2], "paused playback must still queue incoming TTS; got \(captured.map(\.sequence))")
    #expect(await engine.isPlaybackPaused())

    let failure = await consumeFirstEvent(stream, within: .milliseconds(250)) { event in
        if case .failed = event { return event } else { return nil }
    }
    #expect(failure == nil, "queueing while paused must not fail the engine; got \(String(describing: failure))")

    await engine.resumePlayback()
    #expect(await engine.isPlaybackPaused() == false)

    await engine.pausePlayback()
    await engine.stopCapture()
    #expect(await engine.isPlaybackPaused() == false)
    await engine.play(frame: WSAudioFrame(sequence: 3, opusPayload: Data(repeating: 0x03, count: 8)))
    let afterStop = await log.snapshot()
    #expect(afterStop.map(\.sequence) == [1, 2], "stopCapture after pause must retire leftover frames")
}
