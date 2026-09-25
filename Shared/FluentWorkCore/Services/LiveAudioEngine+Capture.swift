@preconcurrency import AVFoundation
import Foundation

extension LiveAudioEngine {
    /// 一次建图之后采集链定型成的东西。
    struct CapturePreparation {
        /// tap 装上用的格式，**同时**是 converter 建出来的源格式。刻意是一个值：
        /// 两者必须一致，而不一致时什么都不会抛。
        let format: AVAudioFormat
        /// 引擎级 voice processing 单元是否在驱动输入。
        let voiceProcessingActive: Bool
        /// 遥测事件那一行 —— 设备日志是在手机上读的，而这一行说的就是那个开关有没有开过。
        let report: String
    }

    public func setSpeechBoundaryMode(_ mode: SpeechBoundaryMode) async {
        speechBoundaryMode = mode
        // 收尾 hold 属于模式：tap-to-start 必须容忍说话人停下来想一想，auto-VAD 不用。
        // `forMode` 同时交回一个没有话在飞的 tracker，那正是切模式需要的 `discard()`。
        speechTracker = .forMode(mode)
    }

    /// 声明下一个采集图是否该跑引擎级 voice processing（回声消除、降噪、AGC）。
    ///
    /// **只记录，不施加**：voice processing 只能在引擎停着时切，所以值在 `startCapture()`
    /// 建图时才生效。会话中途设置因此既不是错误也不是空操作 —— 它改变的是**下一个**会话。
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
        // 最先，在任何守卫之前：这个事件说的是 tap 响过，那是关于**图**的事实，不是关于这个
        // buffer 的去向。挪到中断守卫后面，「tap 从没交付」和「交付了但被这道守卫吃了」就变得
        // 无法区分 —— 不同的 bug，同一个症状。
        if !captureFirstBufferSeen {
            captureFirstBufferSeen = true
            continuation.yield(.captureFirstBuffer)
        }
        // 中断期间丢弃是对的，并且计数，好让「系统中断了我们」和「麦克风什么都没产出」
        // 从外面看不再是同一个观察。
        guard !isSystemInterrupted else {
            interruptionDroppedBuffers += 1
            return
        }
        // `convertToPCM16` 里的 `return nil` 曾是上行最后一道静默闸门。48 kHz 下 tap 每秒响
        // 约 86 次，而一张每个 buffer 都转换失败的图与一张能用的图**无法区分**：tap 仍报告
        // 健康的格式，引擎仍在跑，唯一的症状是网关从没听到的那一轮。每个采集会话报一次 ——
        // 这件事值一行，不值每秒八十六行。
        guard let converter, let sourceFormat else {
            reportCaptureDropOnce("no_converter")
            return
        }
        do {
            guard let pcm = try Self.convertToPCM16(
                buffer,
                converter: converter,
                sourceFormat: sourceFormat
            ) else {
                // 三个格式一起报，因为最可能的原因是 tap 被告知要收到的与实际 buffer 携带的
                // 不一致 —— 开 voice processing 会重塑输入节点，而一个按重塑前格式建出来的
                // converter 会整场会话静默失败。buffer 自己的格式是第三个数字，也是定案的那个。
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

    /// 每个采集会话最多发一次 `.captureDropped`。
    private func reportCaptureDropOnce(_ reason: String) {
        guard !captureDropReported else { return }
        captureDropReported = true
        continuation.yield(.captureDropped(reason: reason))
    }

    /// 发一个语音边界事件，关闭一句话时把收尾事实一起带上。
    ///
    /// 集中在一处，好让每一条开合轮次的路径 —— 能量、tap、`stopCapture` 的 reset ——
    /// 都被同样地度量。一条直接发边界的路径会安静地什么都不贡献给分布，
    /// 而缺失的数据看起来会像一个平静的星期，不像一个 bug。
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
        // `.manual` 两端都由 tap 决定，所以完全不看能量。其余模式让能量关闭这句话；
        // 只有 `.autoVAD` 也让它开一句话。
        guard speechBoundaryMode != .manual else { return }
        let energy = normalizedEnergy(for: pcm)
        let now = clock.now

        if let emitted = speechTracker.register(energy: energy, at: now) {
            yieldSpeechBoundary(emitted)
        }
    }

    /// 会话要求时打开引擎级 voice processing，然后读回 tap 实际会收到的格式。
    ///
    /// 这两件事是**一个操作**，不是两步，因为开启这件事本身会改变输入节点的形状。先读格式
    /// 后开启的调用方拿到的是**处理前**的格式，而 tap 接下来收到的是处理后的流 —— 而且这个
    /// 错误不会抛。格式完全合法，于是 converter 建得出来、tap 装得上，然后每个 buffer 都在
    /// `processInput` 的守卫处被丢掉。
    ///
    /// 开启是尽力而为：拒绝 voice processing 的设备仍必须能采集。丢掉回声消除很糟，
    /// 丢掉麦克风更糟 —— 而两种结果都会被上报，所以事后能分开。
    ///
    /// - Parameter skipEnableReason: 引擎可能在跑时非 `nil`。voice processing 只能在它停着时
    ///   切，而硬问不会礼貌地失败 —— 它会 raise，所以这是个参数，而不是交给调用方去记的事。
    func prepareCaptureNode(
        _ inputNode: AVAudioInputNode,
        skipEnableReason: String?
    ) throws -> CapturePreparation {
        // 问节点它在做什么，而不是问它被要求做什么。单元会同时在两个 I/O 节点上生效，
        // 也可能从上一个会话就开着，所以请求本身决定不了状态 —— 而状态才决定 tap 必须用哪个格式。
        let wasAlreadyOn = inputNode.isVoiceProcessingEnabled
        var isOn = wasAlreadyOn
        var enableFailure: String?

        if voiceProcessingRequested, skipEnableReason == nil, !wasAlreadyOn {
            do {
                isOn = try applyVoiceProcessing(inputNode)
            } catch {
                // 放进 report 而不是抛出去。没有 voice processing 的设备得到一条能用的采集链
                // 和一行说 AEC 关着的日志；它不会得到一个死掉的麦克风。
                enableFailure = error.localizedDescription
                isOn = wasAlreadyOn
            }
        }

        // 在开启尝试**之后**读，并且以读回值为准而不是以请求为准。成功时它们是处理后的格式；
        // 单元关着时它们是原始格式，那正是回退想要的 —— 所以被拒绝或被跳过的开启让旧链保持
        // 原样，而不是半转换状态。
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

    /// 把一个输入 buffer 转成 16 kHz mono interleaved PCM16 字节。
    ///
    /// 源格式是参数而不是读 actor 状态，因为生产与测试钩子走的是同一段转换：转换这件事
    /// 只写一份，测试就不再是它的一个可能走样的复本。
    nonisolated static func convertToPCM16(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        sourceFormat: AVAudioFormat
    ) throws -> Data? {
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
}
