@preconcurrency import AVFoundation
import Foundation

extension LiveAudioEngine {
    /// One line for the telemetry event.
    ///
    /// Reports the state the node was found in, the state it ended in, and the
    /// format the tap got — three facts, because a device run that comes back
    /// "AEC did not help" is unreadable without knowing which of them was true.
    /// `alreadyOn` in particular is not noise: the unit is shared across both
    /// I/O nodes and survives between sessions, so "it was on before we asked"
    /// is a different story from "we turned it on".
    nonisolated static func voiceProcessingReport(
        requested: Bool,
        isOn: Bool,
        wasAlreadyOn: Bool,
        skipReason: String?,
        format: AVAudioFormat,
        failure: String?
    ) -> String {
        if let failure { return "unavailable: \(failure)" }

        let state: String
        if isOn {
            state = wasAlreadyOn ? "on, alreadyOn" : "on"
        } else if requested, let skipReason {
            // The one state that must never read as a plain `off`. The session
            // asked for the unit, this code path could not toggle it, and it is
            // off — reported as `off` it is byte-identical to a build where the
            // flag is off, and the device procedure's rule ("not `on`, don't
            // judge yet") would send the tester off to patch the feature flag
            // and rebuild while the real cause was a running engine.
            state = "off, requested-but-not-applied (\(skipReason))"
        } else {
            state = "off"
        }
        return "\(state), tap=\(Self.describe(format))"
    }

    /// Chooses the format the capture tap is installed with.
    ///
    /// Without voice processing this is the raw input format. With it, the
    /// stream the tap receives is the node's *output* format, not its input
    /// format: the unit sits between them.
    ///
    /// With the unit engaged there is no fallback, and that is deliberate. The
    /// obvious `?? usable(input)` is wrong: while the unit is on the node
    /// produces the *processed* stream, so the raw input format describes a
    /// stream that is no longer there. Tapping it is a format mismatch, and a
    /// format mismatch at the tap is the documented abort site for this very
    /// feature — so the "safe" fallback re-admits the crash it was written to
    /// avoid. Worse, the report would still say `on`, because the unit really is
    /// on; a dead chain would be logged as a healthy one.
    ///
    /// Returning `nil` hands that to the caller, which refuses the session with
    /// both formats in the message.
    nonisolated static func captureFormat(
        input: AVAudioFormat?,
        processedOutput: AVAudioFormat?,
        voiceProcessingActive: Bool
    ) -> AVAudioFormat? {
        guard voiceProcessingActive else { return usable(input) }
        return usable(processedOutput)
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
    /// The default is worse than a bad mix: a discrete multi-channel layout
    /// implies no mapping onto a single channel, so `AVAudioConverter` reports
    /// `channelMap == [-1]`, which the API defines as "this output channel gets
    /// no input at all" — the uplink is *empty*, from a chain that builds
    /// cleanly and throws nothing.
    ///
    /// A no-op for the single-channel formats that arrive without voice
    /// processing, whose default mapping is already `[0]`. `channelMap` composes
    /// with sample-rate conversion, which is why the conversion uses the
    /// block-based `convert(to:error:withInputFrom:)`.
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

    /// Short description of the shared audio session, read at the moment a start
    /// failed.
    ///
    /// An `AVAudioEngine` stops itself when the session it is running on is
    /// deactivated, or when that session's category stops supporting input — and
    /// it does so without executing a line of ours, so `isRunning` going false
    /// leaves no stack to read. The category and mode are the tell: anything but
    /// `.playAndRecord`/`.voiceChat` while a capture session is expected means
    /// another component in this app took the session, which is a different bug
    /// from a system interruption and wants a different fix.
    ///
    /// No `isActive` here — `AVAudioSession` exposes `setActive` but **no**
    /// getter for it, so activity is not reportable and must not be faked from
    /// the manager's own flag (that flag is never cleared in production).
    ///
    /// `sampleRate` stands in for it, and it is the reading that matters most:
    /// category and mode survive deactivation, so a session that has been
    /// switched off still reports `playAndRecord`/`voiceChat` while the engine
    /// it was carrying has already stopped. A deactivated session reports a
    /// **zero** sample rate. This is a proxy, not an API.
    nonisolated static func describeSession() -> String {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        return "category=\(session.category.rawValue) mode=\(session.mode.rawValue)"
            + " sampleRate=\(Int(session.sampleRate)) otherAudio=\(session.isOtherAudioPlaying)"
            + " duckHint=\(session.secondaryAudioShouldBeSilencedHint)"
        #else
        return "session=n/a"
        #endif
    }

    /// Test-only hook exposing the tracker a mode switch configured: the
    /// endpointing hold and auto-start both come from the mode, so a unit test
    /// has to read them through the same path `setSpeechBoundaryMode` writes.
    func _testSpeechTracker() -> AudioSpeechActivityTracker {
        speechTracker
    }

    /// Test-only hook: how many buffers have been handed to the player node.
    /// `play(pcm:)` 不再经过解码器，所以「这一帧有没有被排进播放器」只能从这里看：
    /// `stopCapture()` 之后到达的迟到帧**不**该再被排进去，暂停期间到达的帧**该**排队。
    func _testScheduledBufferCount() -> Int {
        scheduledBufferCount
    }

    /// Test-only hook reporting whether the player node is running.
    /// `scheduleBuffer` queues audio onto a node that plays nothing until it is
    /// started, and nothing else in the test suite can see that.
    func _testPlaybackStarted() -> Bool {
        playerNode.isPlaying
    }

    /// Test-only hook reporting whether the shared engine is running.
    /// `AVAudioPlayerNode.play()` raises — it does not throw — when the engine is
    /// stopped, so "was a node started while the engine was down?" needs both
    /// halves of the answer from the same instant.
    func _testEngineRunning() -> Bool {
        engine.isRunning
    }

    func _testArmEngine() -> EngineStart.Outcome {
        armEngine()
    }

    /// Test-only hook feeding one synthetic buffer through the real
    /// `processInput`.
    ///
    /// The tap needs audio hardware, so every guard inside `processInput` — the
    /// interruption counter, the converter check, the conversion guard — was
    /// otherwise unreachable from a test. The buffer is built here rather than
    /// passed in because `AVAudioPCMBuffer` is not `Sendable`: handing one
    /// across the actor boundary from a test trips region isolation, and working
    /// around that would mean the test no longer drives the same call the tap
    /// does. Silence is enough — these guards decide before any sample is read.
    func _testProcessInputSilentBuffer(frames: AVAudioFrameCount = 160) async {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 1,
                interleaved: true
            ),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return }
        buffer.frameLength = frames
        await processInput(buffer)
    }

    /// Test-only hook exercising `convertToPCM16` for the supplied input buffer
    /// and format, so the tap-chain format test can verify the converter aligns
    /// with the target (16 kHz, mono, interleaved PCM16) without pulling in real
    /// audio hardware.
    ///
    /// The channel map production applies is applied here too. Without it this
    /// hook models a chain that no longer exists: for a multi-channel source the
    /// default mapping is silence, so a hook that skips it would report "the tap
    /// chain works" for input that production turns into an empty uplink.
    nonisolated func _testConvertToPCM16(_ buffer: AVAudioPCMBuffer, from inputFormat: AVAudioFormat) throws -> Data? {
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else {
            return nil
        }
        Self.applyCaptureChannelMap(converter, from: inputFormat)
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
}
