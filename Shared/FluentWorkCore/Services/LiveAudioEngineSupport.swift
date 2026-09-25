@preconcurrency import AVFoundation
import Foundation

public enum AudioEnginePermissionError: Error {
    case microphoneDenied
}

public enum AudioEngineError: Error {
    case invalidFormat(String)
    case audioSessionConflict(String)
}

struct AudioSpeechActivityTracker: Sendable {
    /// auto-VAD 的收尾 hold。那个模式没人点按钮，静音是唯一的信号，hold 决定一轮等多久。
    static let autoVADSilenceHold: Duration = .milliseconds(1500)
    /// tap-to-start 的收尾 hold。刻意比 auto-VAD 长得多：用户是特意开的这一轮，而且通常话说到
    /// 一半，所以找个词时的停顿绝不能提交这一轮。
    static let tapToStartSilenceHold: Duration = .milliseconds(8000)

    private(set) var isSpeechActive = false
    private(set) var lastSpeechAt: ContinuousClock.Instant?

    /// 刚刚关闭的那句话的形状。
    private(set) var lastEndpoint: Endpoint?

    struct Endpoint: Equatable, Sendable {
        /// `manual` —— 用户按了说完了。`silenceHold` —— 房间自己决定的。
        /// 只有第二种会把人在句子中间切断。
        enum Reason: String, Equatable, Sendable {
            case manual
            case silenceHold
        }

        let reason: Reason
        /// 最后一次检测到语音 → 关闭，即房间在提交之前等了多久。hold 就是拿它来衡量的。
        ///
        /// tap 上是 `nil`，它没有尾随静音可测 —— 用 `nil` 而不是零，因为零读起来是
        /// 「用户停了并立刻说完」，那是一个真实且不同的情形。
        let trailingSilence: Duration?
    }

    let speechThreshold: Float
    var silenceHold: Duration
    /// 为 false 时一句话只能经 `forceStart()` 开始；能量仍然负责关闭它。这就是 tap-to-start：
    /// tap 开这一轮，一段稳定的静音提交它，所以一轮只要一个手势而不是两个。
    var autoStart: Bool

    init(
        speechThreshold: Float = 0.015,
        silenceHold: Duration = AudioSpeechActivityTracker.autoVADSilenceHold,
        autoStart: Bool = true
    ) {
        self.speechThreshold = speechThreshold
        self.silenceHold = silenceHold
        self.autoStart = autoStart
    }

    mutating func register(energy: Float, at now: ContinuousClock.Instant) -> AudioEngineEvent? {
        if energy >= speechThreshold {
            lastSpeechAt = now
            guard !isSpeechActive else { return nil }
            guard autoStart else { return nil }
            isSpeechActive = true
            return .speechStarted
        }

        // `lastSpeechAt` 在用户真的说话之前保持 nil，所以一次 tap 之后的静音永远不会提交一个
        // 空轮次 —— 它会落到录制中止那条路径上。
        guard isSpeechActive, let lastSpeechAt else { return nil }
        let trailing = now - lastSpeechAt
        guard trailing >= silenceHold else { return nil }

        isSpeechActive = false
        self.lastSpeechAt = nil
        lastEndpoint = Endpoint(reason: .silenceHold, trailingSilence: trailing)
        return .speechEnded
    }

    mutating func forceStart() -> AudioEngineEvent? {
        guard !isSpeechActive else { return nil }
        isSpeechActive = true
        lastSpeechAt = nil
        return .speechStarted
    }

    mutating func forceEnd() -> AudioEngineEvent? {
        guard isSpeechActive else { return nil }
        discard()
        lastEndpoint = Endpoint(reason: .manual, trailingSilence: nil)
        return .speechEnded
    }

    mutating func reset() -> AudioEngineEvent? {
        let wasActive = isSpeechActive
        discard()
        return wasActive ? .speechEnded : nil
    }

    /// 清掉进行中的话，但**不**发 `.speechEnded`。
    mutating func discard() {
        isSpeechActive = false
        lastSpeechAt = nil
    }

    /// 一个边界模式所蕴含的 tracker —— 模式 → (`autoStart`, `silenceHold`) 映射的唯一真源。
    static func forMode(_ mode: SpeechBoundaryMode) -> AudioSpeechActivityTracker {
        AudioSpeechActivityTracker(
            silenceHold: mode == .tapToStart ? tapToStartSilenceHold : autoVADSilenceHold,
            autoStart: mode == .autoVAD
        )
    }
}

/// 一个会话的音频图被拆掉的顺序。
///
/// 顺序必须遵守的规则：**引擎在跑时不得执行图变更。** `engine.detach(_:)` 与
/// `inputNode.removeTap` 是同一种变更的两种失败形态 —— 前者 raise 一个 `NSException` 而不是
/// 抛，后者是扬声器里的一阵爆音 —— 所以序列才是可能出错的那部分，而它是纯的，因此可以不接
/// 音频设备就被断言。
enum PlaybackTeardown {
    enum Step: Equatable, Sendable {
        case stopPlayer
        case resetPlayer
        case stopKeepAlive
        case resetKeepAlive
        case stopEngine
        case removeTap
        case detachPlayer
        case detachKeepAlive
    }

    /// 从当前状态停止采集时，按序要跑的步骤。
    ///
    /// 引擎在跑就发 `stopEngine`，不管有没有播放器挂着：一个从没播过东西的会话仍然有一张在跑的
    /// 引擎，而留着它跑正是让**下一个**会话的图对着一个陈旧的图工作的原因。
    ///
    /// 图变更（`removeTap`、`detach`）排在 `stopEngine` **之后**。`resetPlayer` 坐在 `stopPlayer`
    /// 与 `stopEngine` 之间，好让排好的 TTS buffer 被丢掉，而不是在停止的过程中以爆音的形式排空。
    static func steps(
        playerAttached: Bool,
        engineRunning: Bool,
        tapInstalled: Bool = false,
        keepAliveAttached: Bool = false
    ) -> [Step] {
        var steps: [Step] = []
        if playerAttached {
            steps.append(.stopPlayer)
            steps.append(.resetPlayer)
        }
        // keep-alive 节点得到 TTS 播放器的完整待遇，detach 也包含在内：一个跨拆图仍挂着的节点
        // 正是下一个会话 `play()` 会 raise 的状态，而「它只是那个静音的」不是
        // `AVAudioPlayerNode` 会在意的属性。
        if keepAliveAttached {
            steps.append(.stopKeepAlive)
            steps.append(.resetKeepAlive)
        }
        if engineRunning {
            steps.append(.stopEngine)
        }
        if tapInstalled {
            steps.append(.removeTap)
        }
        if playerAttached {
            steps.append(.detachPlayer)
        }
        if keepAliveAttached {
            steps.append(.detachKeepAlive)
        }
        return steps
    }
}

enum EngineStart {
    struct Failure: Equatable, Sendable {
        let error: String?
        let interrupted: Bool
        let session: String

        var detail: String {
            let cause: String
            if let error {
                cause = "start() threw: \(error)"
            } else {
                cause = "start() returned normally and the engine is still not running"
            }
            return "engine not running after the start attempt (\(cause)); "
                + "interrupted=\(interrupted) \(session)"
        }
    }

    struct Outcome: Equatable, Sendable {
        let wasRunning: Bool
        let failure: Failure?
    }
}
