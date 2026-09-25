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
    nonisolated static let maxCaptureRecoveries = 3
    private nonisolated let stream: AsyncStream<AudioEngineEvent>
    let continuation: AsyncStream<AudioEngineEvent>.Continuation

    var converter: AVAudioConverter?
    var sourceFormat: AVAudioFormat?
    private var hasInstalledTap = false
    var captureFirstBufferSeen = false
    /// 每个采集会话最多报一次：tap 每秒响约 86 次，一行一 buffer 会把要露的那件事埋掉。
    var captureDropReported = false
    var captureRecoveryAttempts = 0
    /// 中断期间被 `isSystemInterrupted` 守卫吞掉的 buffer 数，中断抬起时上报。
    var interruptionDroppedBuffers = 0
    var speechTracker = AudioSpeechActivityTracker.forMode(.manual)
    /// 本句话从何时开始。tracker 自己没有时钟，时间戳一律由调用方递入。
    var speechStartedAt: ContinuousClock.Instant?
    var speechBoundaryMode: SpeechBoundaryMode = .manual
    /// 会话的**意图**，不是状态：只在建图时施加，因为开关只能在引擎停着时切。
    var voiceProcessingRequested = false
    /// 当前图上的**实际**状态。从节点读回，不从请求推断。
    var voiceProcessingActive = false
    let clock = ContinuousClock()

    let playerNode = AVAudioPlayerNode()
    var playerAttached = false
    /// 整个会话期间循环播静音，让渲染循环在任何东西向麦克风要数据之前就已经转起来。
    ///
    /// 刻意**不是** `playerNode`：那个节点是 TTS 播放器，`interruptNow()` 每次打断都会
    /// 停它并 reset，共用会把麦克风正好在用户说话时重新睡回去。
    let keepAliveNode = AVAudioPlayerNode()
    var keepAliveAttached = false
    /// 循环 buffer 是否已排入。排两次会在第一层循环上再叠一层。
    var keepAliveBufferScheduled = false
    /// 16 kHz 单声道静音，一秒长，循环播放。
    let keepAliveBuffer: AVAudioPCMBuffer? = {
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: LiveAudioEngine.targetFormat,
                frameCapacity: 16_000
            )
        else { return nil }
        // 先设 `frameLength` 再 memset，否则 `mDataByteSize` 描述的还是空 buffer，什么都没清零。
        // 走 buffer list 而不是 `int16ChannelData` —— 后者不是 interleaved 格式的通道访问器。
        buffer.frameLength = 16_000
        for entry in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            if let data = entry.mData {
                memset(data, 0, Int(entry.mDataByteSize))
            }
        }
        return buffer
    }()

    /// `stopCapture()` 拆图时置位。采集与播放共用一张 `AVAudioEngine`，结束会话会同时
    /// 退役两个方向；而 `AVAudioPlayerNode.play()` 在已拆的图上会 raise 而不是 throw。
    var playbackRetired = false

    /// 结束练习确认框开着：播放器暂停、进来的 TTS 仍排队，但不调 `play()`。
    /// 这里清队列会让取消之后接不上。
    var playbackPaused = false
    /// 排进播放器的 buffer 计数。只为 `_testScheduledBufferCount()` 存在。
    var scheduledBufferCount = 0

    /// `interruptNow()` 被请求的时刻，供测试断言本地静音预算，不依赖硬件输出。
    var lastInterruptRequestedAt: ContinuousClock.Instant?
    var isSystemInterrupted = false

    private let sessionManager: any AudioSessionManaging
    let decoder: any WSAudioFrameDecoder
    let interruptionObserver: any AudioInterruptionObserving
    private let requestMicrophonePermission: @Sendable () async -> Bool
    /// 打开引擎级 voice processing 并**返回读回值**而不是 `Void`：因为「问过了、没抛」
    /// 和「单元真的开了」不是同一个事实。可注入是因为真正要紧的那条分支 —— 设备拒绝
    /// 这个单元 —— 健康设备上不会走，也因为这样能让 `swift test` 不碰真实 API。
    let applyVoiceProcessing: @Sendable (AVAudioInputNode) throws -> Bool
    /// 可注入**只为**让 `swift test` 不碰本机输入设备 —— 用真实实现时，在有输入设备的
    /// 开发机上这一步会打开麦克风（系统亮指示、CI 机器开始录音）。
    private let installCaptureTap: @Sendable (AVAudioInputNode, AVAudioFormat, @escaping AVAudioNodeTapBlock) -> NSError?
    /// 把引擎拉起来。**采集与播放共用这一个口子**：两个方向调的是同一个操作。
    /// 可注入是因为真正要紧的那条分支 —— 引擎拒绝启动 —— 健康设备上不会走。
    /// 与 `installCaptureTap` 分开：只堵住 tap，`engine.start()` 仍会因为输入节点被访问而
    /// 打开设备 —— 半堵的替身比不堵更糟，因为它看起来已经安全了。
    let startEngine: @Sendable (AVAudioEngine) throws -> Void
    private let removeCaptureTap: @Sendable (AVAudioEngine) -> Void

    public init(
        sessionManager: any AudioSessionManaging = DefaultAudioSessionManager(),
        decoder: any WSAudioFrameDecoder = RawPCM16FrameDecoder(),
        interruptionObserver: any AudioInterruptionObserving = AudioInterruptionObserver(),
        requestMicrophonePermission: @escaping @Sendable () async -> Bool = {
            await MicrophonePermission.request()
        },
        applyVoiceProcessing: @escaping @Sendable (AVAudioInputNode) throws -> Bool = { node in
            // 两种失败形状、两种机制，这里都需要。`setVoiceProcessingEnabled` 是会抛的
            // Swift 调用，拒绝以 Swift error 到达；而在引擎运行时问它则以另一种方式失败 ——
            // 一个 `AVAEInternal` 的 "required condition is false" raise，而 `NSException`
            // 对 `do/catch` 是不可见的。
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
        startEngine: @escaping @Sendable (AVAudioEngine) throws -> Void = { try $0.start() },
        removeCaptureTap: @escaping @Sendable (AVAudioEngine) -> Void = { $0.inputNode.removeTap(onBus: 0) },
    ) {
        self.startEngine = startEngine
        self.applyVoiceProcessing = applyVoiceProcessing
        self.installCaptureTap = installCaptureTap
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
        // 先要权限再激活会话，否则未授权时激活会以 error 1 失败。
        let granted = await requestMicrophonePermission()
        guard granted else {
            throw AudioEnginePermissionError.microphoneDenied
        }

        try sessionManager.configure(for: .fullDuplex)

        // **先**摸一下 `inputNode`，让图在 `engine.start()` 之前至少挂上一个节点。
        // 没有节点就启动会断言 `inputNode != nullptr || outputNode != nullptr` 并让 App 崩。
        let inputNode = engine.inputNode

        // voice processing 必须在读任何格式**之前**开，因为开启这件事本身会改变输入节点的
        // 形状。`prepareCaptureNode` 把这两半当成一个操作；先读后开不会抛，它会安静地
        // 对着一个已经不存在的流建 converter 和 tap。
        //
        // 即使在这里也要用引擎是否在跑来把关：一个活过自己会话的播放帧会经
        // `startPlaybackIfNeeded()` 把引擎拉起来，而在运行中的引擎上切 voice processing
        // 会 raise 而不是返回错误。
        let preparation = try prepareCaptureNode(
            inputNode,
            skipEnableReason: engine.isRunning ? "engine already running" : nil
        )
        let inputFormat = preparation.format
        // 在引擎启动**之前**上报，这样一个死在 `engine.start()` 里的会话仍然留下 AEC 到底开没开。
        continuation.yield(.voiceProcessing(preparation.report))

        // 用 guard 而不是盲赋值：converter 建不出来会变成 `nil`，`convertToPCM16` 于是对
        // 每个 buffer 都返回 `nil`，`processInput` 安静地把它们全丢掉。
        //
        // 建在拆旧 tap **之前**：拆 tap 在这个窗口里不可逆，而 `hasInstalledTap` 是另外两条
        // 路径据以行动的依据，所以中间抛出去会让标志位声称有一个已经不存在的 tap。
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else {
            throw AudioEngineError.invalidFormat(
                "Could not convert \(Self.describe(inputFormat)) to \(Self.describe(Self.targetFormat)). Check microphone permission or device audio input."
            )
        }
        Self.applyCaptureChannelMap(converter, from: inputFormat)

        // 在 `engine.start()` **之前**装 tap，否则最早的音频 buffer 会丢，说话房间的 UI
        // 永远等不到 `.speechStarted`。
        removeTapIfInstalled(engine)

        // 包起来，而且这一次不是防御性的：`installTap` 是引擎级 voice processing 有文档的
        // 中止点，当交给它的格式与节点实际产出的不匹配时会 raise
        // `AVAEGraphNode.mm … CreateRecordingTap: (IsFormatSampleRateAndChannelCountValid(format))`。
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

        hasInstalledTap = true
        captureDropReported = false
        captureRecoveryAttempts = 0
        captureFirstBufferSeen = false
        sourceFormat = inputFormat
        self.converter = converter
        // 按配置的模式重建，而不是按初始化器的默认值，否则每个会话都会安静地跑在 auto-VAD 配置上。
        speechTracker = .forMode(speechBoundaryMode)

        // 在引擎启动之前建好**整张**图 —— 包括播放节点。在一个**活着的**渲染图上挂接并连线、
        // 然后在同一个同步块里调 `play()`，会让节点对 AVFoundation 看起来是断开的，而
        // `play()` 会 raise "player started when in a disconnected state" 而不是返回。
        attachPlayerIfNeeded()
        attachKeepAliveIfNeeded()

        // `start()` 返回不等于引擎在跑。它可能不抛就回来，然后把引擎留在停止状态，而这件事
        // 过去没有任何人检查：会话接着宣称有一个它并不拥有的麦克风，`startCapture()` 返回成功，
        // 唯一的症状是网关从没听到的那一轮。静音是本项目唯一不可接受的失败，所以在这里就失败。
        startInterruptionObservation()
        let start = armEngine()
        if let failure = start.failure {
            // 拆掉刚装的 tap，好让从干净状态重试不会撞上「tap 已装」的前置条件。
            stopInterruptionObservation()
            removeTapIfInstalled(engine)
            // voice processing 要被提一句，因为它引入了一个这条文案否则会误述的失败：开着它
            // 时输入节点的输出格式和输出节点的输入格式必须一致，所以启动失败可能是格式不匹配
            // 而不是另一个 App 占着会话 —— 这时「关掉你的音乐 App」就是错的建议。
            let voiceProcessingNote = preparation.voiceProcessingActive
                ? ". Voice processing is on (\(Self.describe(inputFormat))); its input and output formats must match."
                : ""
            throw AudioEngineError.audioSessionConflict(failure.detail + voiceProcessingNote)
        }

        // 引擎起来了，播放方向于是又能用了。只在启动成功之后清 —— 一个没起来的会话不得
        // 宣称它拥有一张并不存在的图。
        playbackRetired = false
        playbackPaused = false

        // 在返回前踢一下渲染循环。`.connecting` 等麦克风自证，而麦克风在有什么东西播放之前
        // 一个 buffer 都不交付，所以一个只武装、什么都不播的会话永远进不了 ready。
        let kick = startKeepAlive()
        continuation.yield(.captureKick(started: kick.started, detail: kick.detail))

        // `startCapture` 的最后一行，所以它的出现证明图真的武装好了 —— 而不只是走到了读格式。
        continuation.yield(.captureArmed(
            wasRunning: start.wasRunning,
            running: engine.isRunning,
            // 在这里读，读在答案恰好是 `false` 的那一刻，因为引擎可能已经停下的两种途径 ——
            // 系统中断了我们，或 App 内别的组件重配了共享会话 —— 不留下别的痕迹。
            // 见 `describeSession()`。
            session: Self.describeSession()
        ))
    }

    /// 拆掉已装的采集 tap，并把标志位清掉。
    ///
    /// `hasInstalledTap` 这个不变量的唯一清理点。`deinit` 例外：actor 的 `deinit` 是
    /// nonisolated，调不到这个隔离方法，所以它在原地自己写了一遍守卫。
    private func removeTapIfInstalled(_ engine: AVAudioEngine) {
        guard hasInstalledTap else { return }
        removeCaptureTap(engine)
        hasInstalledTap = false
    }

    func armEngine() -> EngineStart.Outcome {
        let wasRunning = engine.isRunning
        var startError: String?
        if !wasRunning {
            do {
                try startEngine(engine)
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
            // 保留现有的图。因为拔了个耳机就把会话杀掉，比短暂的格式不匹配更糟。
            return
        }

        guard hasInstalledTap else { return }

        let inputNode = engine.inputNode

        // 这条路径**永不**切 voice processing。切换需要停引擎，而停引擎会丢掉助手正在进行的
        // 播放；它还会落在上一个 tap 仍装在 bus 0 上的时候，在一个 tap 所描述的旧格式下面
        // 改变节点产出的格式。
        //
        // 不会丢东西：状态两种情况下都是**读回**的，所以路由变化丢掉的单元给出原始格式，
        // 活下来的单元给出处理后的格式。两者都自洽。
        guard let preparation = try? prepareCaptureNode(inputNode, skipEnableReason: "route change") else {
            // 路由变化之后没有可用格式。保留现有的图，让中断观察者去暴露这个失败。
            return
        }
        let inputFormat = preparation.format

        // 只在节点的流真的动了时才重建。一个既没改格式也没改单元状态的路由变化，过去会
        // 照样把 tap 拆了重装，丢掉正处在轮次中途的任何音频。
        let formatChanged = sourceFormat?.isEqual(inputFormat) != true
            || voiceProcessingActive != preparation.voiceProcessingActive

        if formatChanged {
            // 建在任何东西被拆掉**之前**，这样一个建不出来的 converter 会让能用的那条链留在原地，
            // 而不是换上去一条死的。这条路径不能抛 —— 它是对路由变化的反应，不是会话启动 ——
            // 所以在这里拒绝之外的选项是装上一个 converter 为 `nil` 的 tap，那是静音。
            guard let replacement = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else {
                return
            }
            Self.applyCaptureChannelMap(replacement, from: inputFormat)

            // 包起来，理由与 `startCapture` 的装 tap 相同：这是有文档的中止点，而这条路径
            // 是在会话活着的时候跑的。
            removeTapIfInstalled(engine)
            if let installRaised = installCaptureTap(inputNode, inputFormat, { [weak self] buffer, _ in
                guard let self else { return }
                Task {
                    await self.processInput(buffer)
                }
            }) {
                // 没有 tap，而 `hasInstalledTap` 已经这么说了 —— 会话继续安静地跑，而不是把进程
                // 一起带走。
                continuation.yield(.failed("could not reinstall the capture tap after a route change: \(installRaised.localizedDescription)"))
                return
            }

            hasInstalledTap = true
            sourceFormat = inputFormat
            converter = replacement
            voiceProcessingActive = preparation.voiceProcessingActive
            continuation.yield(.voiceProcessing(preparation.report))
        }

        if !engine.isRunning {
            captureRecoveryAttempts += 1
            guard captureRecoveryAttempts <= Self.maxCaptureRecoveries else {
                continuation.yield(.failed("音频配置反复变化，采集引擎无法保持运行，本轮练习已停止"))
                return
            }
        }

        if let failure = armEngine().failure {
            continuation.yield(
                .failed("could not restart the engine after a route change: \(failure.detail)")
            )
        }
    }

    public func stopCapture() async {
        stopInterruptionObservation()
        // 在一切会 yield 或改图的东西**之前**退休。来自尚未关闭的 socket 的迟到 TTS 帧仍会调
        // `play(pcm:)`；这个标志一置，它们就丢弃，而不是把播放器重新拉起来（也不是 `.failed`，
        // 那会杀掉进程级的音频泵）。
        playbackRetired = true
        playbackPaused = false
        // 也停掉在途的 AI 播放，并把节点 detach 掉，好让下一个会话重新挂到一张真的存在的图上。
        // 留着它们挂着正是让**下一次** `play()` 危险的原因：图马上要被拆掉，而 `playerAttached`
        // 会继续声称那个节点没问题。
        for step in PlaybackTeardown.steps(
            playerAttached: playerAttached,
            engineRunning: engine.isRunning,
            tapInstalled: hasInstalledTap,
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
                // 排好的循环跟着 reset 一起没了，所以下一个会话必须重新排，不能假定它还在。
                keepAliveBufferScheduled = false
            case .stopEngine:
                engine.stop()
            case .removeTap:
                removeTapIfInstalled(engine)
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

        // **不要在这里 deactivate 音频会话。** 在 AI 音频仍在播放时（aiSpeaking→waitingUser
        // 过渡期间）deactivate 会让 AVAudioEngine 的内部图 uninitialize，导致下一次
        // `engine.start()` 或任何节点访问撞上
        // `required condition is false: inputNode != nullptr || outputNode != nullptr`。
        // 会话在整个说话房间会话期间保持 active，只在 App 显式结束会话或进入后台时才 deactivate。
    }
}
