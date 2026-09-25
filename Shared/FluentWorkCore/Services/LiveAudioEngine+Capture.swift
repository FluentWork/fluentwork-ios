@preconcurrency import AVFoundation
import Foundation

extension LiveAudioEngine {
    /// What the capture chain resolved to for one graph build.
    struct CapturePreparation {
        /// The format the tap is installed with *and* the format the converter
        /// is built from. One value on purpose: the two have to agree, and when
        /// they do not nothing throws.
        let format: AVAudioFormat
        /// Whether the engine-level voice-processing unit is driving the input.
        let voiceProcessingActive: Bool
        /// One line for the telemetry event — device logs are read on a phone,
        /// and this is what says whether the switch was on before anyone tries
        /// to judge how well it worked.
        let report: String
    }

    public func setSpeechBoundaryMode(_ mode: SpeechBoundaryMode) async {
        speechBoundaryMode = mode
        // The endpointing hold belongs to the mode: tap-to-start has to tolerate
        // a speaker pausing to think, auto-VAD does not. `forMode` also hands
        // back a tracker with no speech in flight, which is the `discard()` a
        // mode switch needs.
        speechTracker = .forMode(mode)
    }

    /// Declares whether the next capture graph should run engine-level voice
    /// processing — the echo canceller, noise suppression and AGC that keep the
    /// assistant from hearing its own voice through the speaker.
    ///
    /// Recorded, not applied: voice processing may only be toggled while the
    /// engine is stopped, so the value takes effect when `startCapture()` builds
    /// the graph. Setting it mid-session is therefore not an error and not a
    /// no-op either — it changes the *next* session, which is what makes the
    /// feature flag usable as a comparison harness on a device.
    public func setVoiceProcessingEnabled(_ enabled: Bool) async {
        voiceProcessingRequested = enabled
    }

    public func beginManualSpeech() async {
        if let emitted = speechTracker.forceStart() {
            yieldSpeechBoundary(emitted)
        }
    }

    public func endManualSpeech() async {
        if let emitted = speechTracker.forceEnd() {
            yieldSpeechBoundary(emitted)
        }
    }

    public func discardActiveSpeech() async {
        speechTracker.discard()
    }

    func processInput(_ buffer: AVAudioPCMBuffer) async {
        // First, before ANY guard: the event says the tap fired, which is a fact
        // about the graph, not about this buffer's fate. Behind the interruption
        // guard, "the tap never delivered" and "the tap delivered and this guard
        // ate it" become indistinguishable — different bugs, same symptom.
        if !captureFirstBufferSeen {
            captureFirstBufferSeen = true
            continuation.yield(.captureFirstBuffer)
        }
        // Correct to drop during an interruption, and counted so that "the
        // system interrupted us" and "the microphone produced nothing" stop
        // being the same observation from the outside.
        guard !isSystemInterrupted else {
            interruptionDroppedBuffers += 1
            return
        }
        // The `return nil`s inside `convertToPCM16` were the last silent gate on
        // the uplink. At 48 kHz the tap fires ~86 times a second, and a graph
        // whose every buffer fails conversion is indistinguishable from one that
        // works: the tap still reports a healthy format, the engine still runs,
        // and the only symptom is a turn the gateway never heard. Reported once
        // per capture session — the fact is worth one line, not eighty-six a
        // second.
        guard converter != nil, sourceFormat != nil else {
            reportCaptureDropOnce("no_converter")
            return
        }
        do {
            guard let pcm = try convertToPCM16(buffer) else {
                // The formats ride along because the likeliest cause is a
                // mismatch between what the tap was told it would receive and
                // what the buffers actually carry — enabling voice processing
                // reshapes the input node, and a converter built from the
                // pre-reshape format fails silently for the whole session. The
                // buffer's own format is the third number, and the one that
                // settles it.
                reportCaptureDropOnce(
                    "conversion_produced_no_pcm src=\(Self.describe(sourceFormat)) "
                        + "target=\(Self.describe(Self.targetFormat)) "
                        + "buffer=\(Self.describe(buffer.format)) "
                        + "frames=\(buffer.frameLength)"
                )
                return
            }
            continuation.yield(.pcmChunk(pcm))
            updateSpeechState(using: pcm)
        } catch {
            continuation.yield(.failed(error.localizedDescription))
        }
    }

    /// Emits `.captureDropped` at most once per capture session.
    private func reportCaptureDropOnce(_ reason: String) {
        guard !captureDropReported else { return }
        captureDropReported = true
        continuation.yield(.captureDropped(reason: reason))
    }

    /// Yields a speech-boundary event, attaching the endpointing facts when it
    /// closes an utterance.
    ///
    /// Kept in one place so every path that opens or closes a turn — energy,
    /// the tap, and `stopCapture`'s reset — is measured the same way. A path
    /// that emitted its boundary directly would silently contribute nothing to
    /// the distribution, and the missing data would look like a quiet week.
    func yieldSpeechBoundary(_ event: AudioEngineEvent) {
        switch event {
        case .speechStarted:
            speechStartedAt = clock.now
            continuation.yield(event)

        case .speechEnded:
            let now = clock.now
            let facts = speechTracker.lastEndpoint
            continuation.yield(.speechEndpointed(
                reason: facts?.reason.rawValue ?? "unknown",
                windowMs: speechStartedAt.map { Self.milliseconds($0.duration(to: now)) },
                trailingSilenceMs: facts?.trailingSilence.map(Self.milliseconds)
            ))
            speechStartedAt = nil
            continuation.yield(event)

        default:
            continuation.yield(event)
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int((duration / .milliseconds(1)).rounded())
    }

    private func updateSpeechState(using pcm: Data) {
        // `.manual` decides both ends with taps, so energy is not consulted at
        // all. The other modes let energy close the utterance; only `.autoVAD`
        // also lets it open one.
        guard speechBoundaryMode != .manual else { return }
        let energy = normalizedEnergy(for: pcm)
        let now = clock.now

        if let emitted = speechTracker.register(energy: energy, at: now) {
            yieldSpeechBoundary(emitted)
        }
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
    ///
    /// Enabling is best-effort: a device that refuses voice processing must
    /// still capture. Losing echo cancellation is bad, losing the microphone is
    /// worse — and the outcome is reported either way, so the two can be told
    /// apart afterwards.
    ///
    /// - Parameter skipEnableReason: non-`nil` when the engine may be running.
    ///   Voice processing can only be toggled while it is stopped, and asking
    ///   anyway does not fail politely — it raises, which is why this is a
    ///   parameter rather than something the caller is trusted to remember.
    func prepareCaptureNode(
        _ inputNode: AVAudioInputNode,
        skipEnableReason: String?
    ) throws -> CapturePreparation {
        // The node is asked what it is doing, not what was asked of it. The unit
        // engages on both I/O nodes at once and can already be on from an
        // earlier session, so the request alone does not determine the state —
        // and the state is what decides which format the tap has to use.
        let wasAlreadyOn = inputNode.isVoiceProcessingEnabled
        var isOn = wasAlreadyOn
        var enableFailure: String?

        if voiceProcessingRequested, skipEnableReason == nil, !wasAlreadyOn {
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
        // than the request. On success these are the processed formats; when the
        // unit is off they are the raw ones, which is what the fallback wants —
        // so a refused or skipped enable leaves the old chain untouched rather
        // than half-converted.
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
                requested: voiceProcessingRequested,
                isOn: isOn,
                wasAlreadyOn: wasAlreadyOn,
                skipReason: skipEnableReason,
                format: format,
                failure: enableFailure
            )
        )
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
}
