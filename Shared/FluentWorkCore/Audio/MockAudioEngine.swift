#if DEBUG
import FluentWorkNetworking
import Foundation

/// 设备替身的统一开关（`FW_MOCK_MIC`）。
///
/// 麦克风在客户端有**三个**入口，替身必须把三处都接过来，否则「验证不依赖真机」
/// 只是半句话：引擎的采集（本文件）、UI 的权限请求（`MicrophonePermission`）、
/// 音频会话的类别（`.playAndRecord` 会让系统一直显示麦克风在用）。
public enum MockDeviceMode {
    /// 是否开着麦克风替身。
    ///
    /// **测试进程里恒为 `true`。** 这条判据是 `MicrophonePermission.request()` 的
    /// 第一道分支（为真则直接返回 true、不碰 `AVAudioSession`），而它原先只读
    /// `FW_MOCK_MIC` —— 测试进程没人设这个变量，于是测试里它恒为假，权限请求会
    /// 一路走到真的 `requestRecordPermission`。macOS 上被 `#if os(iOS)` 挡住，
    /// 但 iOS 模拟器上跑测试会真的去问系统：那就是「测试在调用真机的麦克风」。
    ///
    /// 与 `AppDependencies.TestProcess` 用同一个判据，避免两处对「这是不是测试」
    /// 给出不同答案。真机验证时 `FW_MOCK_MIC` 仍然说了算。
    public static var isMicrophoneMocked: Bool {
        if TestProcess.isRunning { return true }
        return MockAudioEngine.Script.fromEnvironment() != nil
    }
}

/// 麦克风的运行时替身（**仅 DEBUG**）。
///
/// 让一条完整的语音轮次在「没有麦克风、没有权限、没有人对着手机说话」的条件下
/// 跑完。真机联调时它是必需的：一旦用人声喂链路，每次验证都要有人开口、每句话
/// 都不一样、VAD 的收尾时刻还依赖环境噪声 —— 而我们要验的是**音频回来之后的
/// 那半条链路**，不是麦克风。
///
/// ## 为什么只替采集，不替播放
///
/// `playback` 持有的就是生产用的 `LiveAudioEngine`，播放/打断全部转发给它。
/// 「能不能出声」是这条链路上唯一只能靠耳朵裁决的判据（单测看不到静音，
/// 这是本仓的老教训），把播放一起替掉就等于把这条判据也丢了。
///
/// ## 开法（Xcode scheme → Run → Arguments → Environment Variables）
///
/// ```
/// FW_MOCK_MIC=1                 # 打开替身；点一次「开始说话」= 说一句脚本化的
/// FW_MOCK_MIC_UTTERANCE_MS=1500 # 这一句持续多久（默认 1500ms）
/// FW_MOCK_MIC_AUTO_MS=4000      # 可选：无人值守，每 4 秒自动说一句
/// ```
///
/// 一轮的动作：`speechStarted` → 每 20ms 一块 16kHz mono PCM16（1kHz 正弦，
/// 与 dev-echo 的 fixture 同一种音频）→ `speechEnded`。
/// **UI 不用改**：默认的 tap-to-start 一次点击就是一轮，收尾由脚本负责，
/// 不需要 VAD 也不需要人说第二句话。
public actor MockAudioEngine: AudioEngineProtocol {
    /// 一句话的脚本。
    public struct Script: Sendable, Equatable {
        /// 这一句持续多久。
        public var utteranceDuration: Duration
        /// 音频块的间隔（也是每块的长度：20ms）。
        public var chunkInterval: Duration
        /// 自动说话的周期；`nil` = 只能手动触发（点按钮）。
        public var autoRepeat: Duration?

        public init(
            utteranceDuration: Duration = .milliseconds(1500),
            chunkInterval: Duration = .milliseconds(20),
            autoRepeat: Duration? = nil
        ) {
            self.utteranceDuration = utteranceDuration
            self.chunkInterval = chunkInterval
            self.autoRepeat = autoRepeat
        }

        /// 从环境变量读脚本。没设 `FW_MOCK_MIC` 就返回 `nil`（替身不生效）。
        public static func fromEnvironment(
            _ environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Script? {
            guard let raw = environment["FW_MOCK_MIC"], !raw.isEmpty, raw != "0" else {
                return nil
            }
            func ms(_ key: String) -> Int? {
                guard let raw = environment[key], let value = Int(raw), value > 0 else { return nil }
                return value
            }
            return Script(
                utteranceDuration: .milliseconds(ms("FW_MOCK_MIC_UTTERANCE_MS") ?? 1500),
                autoRepeat: ms("FW_MOCK_MIC_AUTO_MS").map { .milliseconds($0) }
            )
        }
    }

    /// 16kHz mono PCM16 的 1kHz 正弦，每块 20ms —— 与 `dev-echo` 的 fixture
    /// 同一种音频，出问题时不至于要分辨「是替身的问题还是链路的问题」。
    private static let sampleRate = 16_000.0
    private static let toneHz = 1_000.0
    private static let samplesPerChunk = 320 // 20ms @ 16kHz

    private let script: Script
    /// 播放那一半：真引擎。采集被替掉，播放不能 —— 见类型注释。
    private let playback: any AudioEngineProtocol
    /// 采集开始时本来会把音频会话配成 `.playAndRecord`（麦克风一直亮着）。
    /// 替身改成只配播放：听得见 TTS，但没有任何东西在录音。
    private let preparePlaybackSession: (@Sendable () throws -> Void)?
    /// 上面那一步的**归还**。替身也必须配对：`preparePlaybackSession` 在生产里是一次
    /// `claim(.playback)`（租约），不还的话名册上会永远挂着一个名字 —— 于是此后任何一次归还
    /// 都判「还有人占着」，再也 deactivate。真机用替身跑时这条路径就是主路径，不能漏。
    private let releasePlaybackSession: (@Sendable () throws -> Void)?

    /// `nonisolated` 与 `LiveAudioEngine` 保持一致：`events()` 是同步要求，
    /// 调用方在任意上下文里取流，不能要求先跳到这个 actor 上。
    private nonisolated let stream: AsyncStream<AudioEngineEvent>
    private let continuation: AsyncStream<AudioEngineEvent>.Continuation
    /// 第二路（见 `AudioEngineProtocol.captureEventStream()`）。替身也必须有 —— 它正是
    /// 「无人值守验证闪测采集」时唯一在产音频的那一路。
    private nonisolated let captureStream: AsyncStream<AudioEngineEvent>
    private let captureContinuation: AsyncStream<AudioEngineEvent>.Continuation

    private var utteranceTask: Task<Void, Never>?
    private var autoTask: Task<Void, Never>?
    private var isSpeaking = false
    /// 正弦相位在块之间连续，拼起来才是一个音而不是每 20ms 一个小咔哒。
    private var sampleOffset = 0
    /// 整条进程只报一次 `.captureFirstBuffer`（与真引擎的 tap 第一次回调同形）。
    private var hasReportedFirstBuffer = false

    public init(
        script: Script,
        playback: any AudioEngineProtocol,
        preparePlaybackSession: (@Sendable () throws -> Void)? = nil,
        releasePlaybackSession: (@Sendable () throws -> Void)? = nil
    ) {
        self.script = script
        self.playback = playback
        self.preparePlaybackSession = preparePlaybackSession
        self.releasePlaybackSession = releasePlaybackSession
        let pair = AsyncStream.makeStream(of: AudioEngineEvent.self)
        self.stream = pair.stream
        self.continuation = pair.continuation
        let capturePair = AsyncStream.makeStream(of: AudioEngineEvent.self)
        self.captureStream = capturePair.stream
        self.captureContinuation = capturePair.continuation
    }

    // MARK: - Capture (mocked)

    /// 起了几次采集。真引擎的 `startCapture()` **不幂等**（会拆了重装 tap），所以
    /// 「整轮只起一次」这条契约得有人在替身上钉住 —— 记数就是为了让它可断言。
    private(set) var startCaptureCalls = 0
    /// 同上，停了几次。
    private(set) var stopCaptureCalls = 0

    public func startCapture() async throws {
        startCaptureCalls += 1
        // 不碰麦克风、不申请权限 —— 这正是这个替身存在的理由。会话只配成播放：
        // 生产那条 `.playAndRecord` 会让系统全程显示麦克风在用。
        try preparePlaybackSession?()
        if let period = script.autoRepeat, autoTask == nil {
            autoTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: period)
                    guard !Task.isCancelled else { return }
                    await self?.beginManualSpeech()
                }
            }
        }
    }

    public func stopCapture() async {
        stopCaptureCalls += 1
        autoTask?.cancel()
        autoTask = nil
        utteranceTask?.cancel()
        utteranceTask = nil
        isSpeaking = false
        await playback.stopCapture()
        // 归还认领（放在最后：I/O 都停了再谈会话），与 `startCapture` 里的那次成对。
        try? releasePlaybackSession?()
    }

    public nonisolated func events() -> AsyncStream<AudioEngineEvent> {
        stream
    }

    public nonisolated func captureEventStream() -> AsyncStream<AudioEngineEvent> {
        captureStream
    }

    public func setVoiceProcessingEnabled(_ enabled: Bool) async {
        // 采集图是假的，但这条日志不能缺：设备运行时要能一眼看出麦克风被替身接管了，
        // 否则「AEC 没生效」和「根本没走采集」在日志上长得一样。
        continuation.yield(.voiceProcessing("mock mic: \(enabled ? "on" : "off"), no capture graph"))
    }

    public func beginManualSpeech() async {
        guard !isSpeaking else { return }
        isSpeaking = true
        continuation.yield(.speechStarted)
        captureContinuation.yield(.speechStarted)

        let interval = script.chunkInterval
        let chunkCount = max(
            1,
            Int(script.utteranceDuration / interval)
        )
        utteranceTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<chunkCount {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                await self.emitChunk()
            }
            await self.finishUtterance()
        }
    }

    public func endManualSpeech() async {
        await finishUtterance()
    }

    public func discardActiveSpeech() async {
        // 契约：丢掉正在进行的这一句，**不发** `speechEnded` ——
        // 发了客户端就会给网关送一个空轮次（I20 的 recording abort 依赖这条）。
        utteranceTask?.cancel()
        utteranceTask = nil
        isSpeaking = false
    }

    private func emitChunk() async {
        guard isSpeaking else { return }
        // 真引擎的「首个 buffer」来自采集 tap 的第一次回调，而房间的 `.connecting` **等的就是
        // 它**（`socketReady` 与 `captureLive` 两半都要到，见 `SpeechSessionMachine`）。
        // 替身没有 tap，它交付的第一个 buffer 就是这一块 —— 不上报这一条，替身模式下房间
        // 永远停在「连接中」，直到 10 秒的 connectWait 把它判失败：那时驱动看到的是
        // 「采集没起来」，而真相是**替身没有食言，只是没人告诉房间它交付了**。
        if !hasReportedFirstBuffer {
            hasReportedFirstBuffer = true
            continuation.yield(.captureFirstBuffer)
        }
        let chunk = Self.toneChunk(offset: sampleOffset)
        continuation.yield(.pcmChunk(chunk))
        // 两路同一份事件，见 `captureEventStream()` 的契约。
        captureContinuation.yield(.pcmChunk(chunk))
        sampleOffset += Self.samplesPerChunk
    }

    private func finishUtterance() async {
        guard isSpeaking else { return }
        utteranceTask?.cancel()
        utteranceTask = nil
        isSpeaking = false
        continuation.yield(.speechEnded)
        // ⚠️ 第二路**必须**有这个收尾：闪测按「话音落下」收尾（稿子），不是死等 5 秒。
        captureContinuation.yield(.speechEnded)
    }

    /// 20ms 的 1kHz 正弦（16kHz mono PCM16）。
    private static func toneChunk(offset: Int) -> Data {
        var data = Data(capacity: samplesPerChunk * 2)
        for index in 0..<samplesPerChunk {
            let t = Double(offset + index) / sampleRate
            let sample = Int16(16_000 * sin(2 * .pi * toneHz * t))
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    // MARK: - Playback (forwarded to the real engine)

    public func play(pcm: Data) async {
        await playback.play(pcm: pcm)
    }

    public func interruptNow() async {
        await playback.interruptNow()
    }

    public func pausePlayback() async {
        await playback.pausePlayback()
    }

    public func resumePlayback() async {
        await playback.resumePlayback()
    }

    public func reconfigureForRouteChange() async {
        await playback.reconfigureForRouteChange()
    }

    /// 转发给真引擎：替身自己的采集认领是 `.playback`，已经由 `stopCapture()` 里的
    /// `releasePlaybackSession` 还掉了；而 `playback`（真引擎）可能在路由变化时认领过
    /// `.fullDuplex`，这里就是它的归还点。
    public func releaseSessionClaim() async {
        await playback.releaseSessionClaim()
    }
}
#endif
