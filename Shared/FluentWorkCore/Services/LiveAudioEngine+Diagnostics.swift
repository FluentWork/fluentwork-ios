@preconcurrency import AVFoundation
import Foundation

extension LiveAudioEngine {
    /// 遥测那一行。
    ///
    /// 报节点被找到时的状态、结束时的状态，以及 tap 拿到的格式 —— 三个事实，因为一次带回来
    /// 「AEC 没帮上忙」的设备运行，在不知道哪一个是真的时候读不了。`alreadyOn` 尤其不是噪音：
    /// 单元跨两个 I/O 节点共享且跨会话存活，所以「在我们问之前它就开着」和「是我们打开的」
    /// 是两个不同的故事。
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
            // 唯一一个绝不能读成朴素 `off` 的状态。会话要了这个单元，这条路径切不了它，而它是
            // 关的 —— 报成 `off` 就与开关本来就关的构建逐字相同，设备流程的规则（「不是 `on`，
            // 先别下判断」）会把测试者打发去改 feature flag 并重建，而真正的原因是引擎在跑。
            state = "off, requested-but-not-applied (\(skipReason))"
        } else {
            state = "off"
        }
        return "\(state), tap=\(Self.describe(format))"
    }

    /// 选采集 tap 装上时用的格式。
    ///
    /// 没有 voice processing 时就是原始输入格式。有它时，tap 收到的流是节点的**输出**格式，
    /// 不是它的输入格式：单元坐在两者之间。
    ///
    /// 单元开着时**没有回退**，这是刻意的。那个显然的 `?? usable(input)` 是错的：单元开着时
    /// 节点产出的是**处理后**的流，所以原始输入格式描述的是一条已经不存在的流。对着它装 tap
    /// 就是格式不匹配，而格式不匹配正是这个特性有文档的中止点 —— 于是那个「安全」的回退把它
    /// 本来要避免的崩溃重新放了进来。更糟的是 report 仍然会说 `on`，因为单元确实开着；
    /// 一条死链会被记成健康的一条。
    ///
    /// 返回 `nil` 就是把这个交给调用方，由它带着两个格式拒绝会话。
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

    /// 输入多于一个通道时只取通道 0。
    ///
    /// voice processing 交回的不是麦克风信号的干净副本 —— 它交回麦克风通道**加上**回声消除器
    /// 干活需要的那些通道。只有通道 0 是说话人。
    ///
    /// 默认值比一个糟糕的混音更糟：离散多通道布局隐含了到单通道的**无**映射，于是
    /// `AVAudioConverter` 报告 `channelMap == [-1]`，而 API 把它定义为「这个输出通道完全没有
    /// 输入」—— 上行是**空的**，来自一条建得干干净净、什么都不抛的链。
    ///
    /// 对没有 voice processing 时到达的单通道格式是空操作，它们的默认映射已经是 `[0]`。
    /// `channelMap` 与采样率转换是可组合的，所以转换用的是基于 block 的
    /// `convert(to:error:withInputFrom:)`。
    nonisolated static func applyCaptureChannelMap(
        _ converter: AVAudioConverter,
        from format: AVAudioFormat
    ) {
        guard format.channelCount > 1 else { return }
        converter.channelMap = [0]
    }

    /// 供遥测用的格式短描述 —— 采样率与通道数是解释一条出错的采集链的两个数字。
    nonisolated static func describe(_ format: AVAudioFormat?) -> String {
        guard let format else { return "none" }
        return "\(Int(format.sampleRate))Hz/\(format.channelCount)ch"
    }

    /// 共享音频会话的短描述，在启动失败的那一刻读。
    ///
    /// 引擎跑着的会话被 deactivate、或那个会话的类别不再支持输入时，`AVAudioEngine` 会自己
    /// 停下 —— 而且它不执行我们任何一行代码，所以 `isRunning` 变 false 不留下栈可读。类别与
    /// 模式就是线索：一个采集会话被期待时，除了 `.playAndRecord`/`.voiceChat` 之外的任何东西
    /// 都意味着这个 App 里的另一个组件把会话拿走了，那是与系统中断不同的 bug，要不同的修法。
    ///
    /// 这里**没有** `isActive`：`AVAudioSession` 暴露 `setActive` 但**没有** getter，所以活动性
    /// 不可上报，也不能用管理器自己的标志位伪造（那个标志在生产里从不被清）。
    ///
    /// `sampleRate` 代它出场，而它是最要紧的那个读数：类别与模式在 deactivate 之后存活，所以
    /// 一个已被关掉的会话仍报告 `playAndRecord`/`voiceChat`，而它承载的引擎已经停了。
    /// 一个被 deactivate 的会话报告**零**采样率。这是代理，不是 API。
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

    /// 暴露一次模式切换所配置出来的 tracker：收尾 hold 与自动开始都来自模式，所以单元测试必须
    /// 走 `setSpeechBoundaryMode` 写入的同一条路径去读它们。
    func _testSpeechTracker() -> AudioSpeechActivityTracker {
        speechTracker
    }

    /// 有多少 buffer 被交给了播放节点。`play(pcm:)` 不经过解码器，所以「这一帧有没有被排进
    /// 播放器」只能从这里看：`stopCapture()` 之后到达的迟到帧**不**该再被排进去，暂停期间到达
    /// 的帧**该**排队。
    func _testScheduledBufferCount() -> Int {
        scheduledBufferCount
    }

    /// 播放节点是否在跑。`scheduleBuffer` 把音频排到一个在启动前什么都不播的节点上，而测试套件
    /// 里没有别的东西看得到那件事。
    func _testPlaybackStarted() -> Bool {
        playerNode.isPlaying
    }

    /// 共享引擎是否在跑。引擎停着时 `AVAudioPlayerNode.play()` 会 raise 而不是抛，所以
    /// 「有没有在引擎停着的时候启动过节点」需要同一瞬间的两半答案。
    func _testEngineRunning() -> Bool {
        engine.isRunning
    }

    func _testArmEngine() -> EngineStart.Outcome {
        armEngine()
    }

    /// 把一个合成 buffer 喂过真实的 `processInput`。
    ///
    /// tap 需要音频硬件，所以 `processInput` 里的每一道守卫 —— 中断计数、converter 检查、转换
    /// 守卫 —— 否则都从测试里够不到。buffer 在这里建而不是由外部传入，因为 `AVAudioPCMBuffer`
    /// 不是 `Sendable`：从测试跨 actor 边界递一个会触发区域隔离，而绕过它就意味着测试不再驱动
    /// tap 驱动的那同一个调用。静音够了 —— 这些守卫在任何样本被读之前就决定了。
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

    /// 用给定的输入 buffer 与格式驱动 `convertToPCM16`，好让 tap 链的格式测试不必拉进真实音频
    /// 硬件就能验证 converter 与目标（16 kHz、mono、interleaved PCM16）对齐。
    ///
    /// 走的是生产用的**同一个** `convertToPCM16`，不是它的复本 —— 复本会走样，而它一走样，
    /// 测试就会对一条生产里已经不存在的链说「能用」。
    nonisolated func _testConvertToPCM16(_ buffer: AVAudioPCMBuffer, from inputFormat: AVAudioFormat) throws -> Data? {
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else {
            return nil
        }
        Self.applyCaptureChannelMap(converter, from: inputFormat)
        return try Self.convertToPCM16(buffer, converter: converter, sourceFormat: inputFormat)
    }
}
