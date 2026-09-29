@preconcurrency import AVFoundation
import Foundation

public enum AudioEnginePermissionError: Error {
    case microphoneDenied
}

public enum AudioEngineError: Error {
    case invalidFormat(String)
    case audioSessionConflict(String)
    /// 认领共享音频会话失败，带着**系统真正说的**那一对 domain + code。
    ///
    /// 单独一个 case 而不是把描述塞进 `.audioSessionConflict(String)`：后者把
    /// 「配置失败」与「激活失败」说成同一件事，而这两件事的处置完全不同
    /// （一个是我们自己传错了东西，另一个是别人正占着系统资源）。见 `AudioSessionClaimFailure`。
    case audioSessionClaimFailed(AudioSessionClaimFailure)
}

/// 一次会话认领失败时，系统到底说了什么。
///
/// **保真的理由与本仓对传输错误的口径一致**：`URLSessionSocketTransport.mapError` 特意保留
/// `[domain code]`，注释写着「那是分辨 transport reset / 帧协议违约 / 服务端关闭的唯一途径」。
/// 会话这条路更具体 —— iOS SDK 头文件 `AVAudioSession.h:250-255` 点名了不同成因：
/// 别人正在通话/占着麦克风时，以 `Record`/`PlayAndRecord` 激活会失败在
/// `AVAudioSessionErrorCodeInsufficientPriority`；反激活那侧还有 `AVAudioSessionErrorCodeIsBusy`
/// （iOS 26.0 起不再返回）。把这两件事合并成一句「请关掉正在用音频的 App」，
/// 就是把「换一个 App 就好」和「等一下再试」说成同一句话。
public struct AudioSessionClaimFailure: Error, Equatable, Sendable {
    public enum Stage: String, Sendable {
        /// `setCategory` / 首选值那一组。
        case configure
        /// `setActive(true)`。
        case activate
    }

    public var stage: Stage
    /// 原样的 `NSError` 三元组。判据与日志都靠它，而不是靠一句重述。
    public var domain: String
    public var code: Int
    public var rawDescription: String

    public init(stage: Stage, error: any Error) {
        let nsError = error as NSError
        self.stage = stage
        self.domain = nsError.domain
        self.code = nsError.code
        self.rawDescription = nsError.localizedDescription
    }

    /// 给 tracker / 日志的完整一行：两个「哪一步」与「哪个错误」都在。
    public var telemetrySummary: String {
        "\(stage.rawValue) \(domain) \(code): \(rawDescription)"
    }

    /// iOS 上「没优先权拿到麦克风」的那个码。
    ///
    /// `#if os(iOS)` 是必须的：`AVAudioSession` 在 macOS 上不存在，而这一层要在 CI（macOS）
    /// 上编译并测试。于是这里的取舍是：**判别式在真机上生效，文案结构在 CI 上被钉住**
    /// （判据走 `userFacingText(treatingCodeAsInsufficientPriority:)` 这个注入点）。
    public static var insufficientPriorityCode: Int? {
        #if os(iOS)
        return AVAudioSession.ErrorCode.insufficientPriority.rawValue
        #else
        return nil
        #endif
    }
}

extension AudioSessionClaimFailure: LocalizedError {
    public var errorDescription: String? {
        userFacingText(treatingCodeAsInsufficientPriority: Self.insufficientPriorityCode)
    }

    /// 人话在前、机器码进括号 —— 与 `userFacingErrorText`（网关错误码表）同一口径：
    /// 学员读到一句能照着做的话，支持读到能查的标识符，谁也不替谁。
    ///
    /// `internal` 而不是 `private`：判据要能绕过平台差异（macOS 上没有
    /// `AVAudioSession.ErrorCode`），把两条分支的文案结构都钉住。
    func userFacingText(treatingCodeAsInsufficientPriority insufficientPriority: Int?) -> String {
        let appendix = "\(domain) \(code)"
        if stage == .activate,
           domain == NSOSStatusErrorDomain,
           code == insufficientPriority {
            return "另一个 App 正在使用麦克风（例如通话或录音），请先结束它再试一次（\(appendix)）"
        }
        switch stage {
        case .activate:
            return "音频会话被系统占着，暂时无法开始练习，请稍后重试（\(appendix)）"
        case .configure:
            return "无法配置音频会话，请稍后重试（\(appendix)）"
        }
    }
}

/// 三个 case 的用户文案。
///
/// `.invalidFormat` / `.audioSessionConflict` 的描述文本**不进用户视野**：它们的 `String`
/// 载荷是给 tracker 的现场细节（格式、会话遥测、底层错误），而 `LocalizedError` 这一层只出
/// 一句能照着做的话。改这两条文案是产品决定，但它们至少不能再落到 NSError 桥接的
/// "The operation couldn't be completed. (FluentWorkCore.AudioEngineError error 0.)" ——
/// 那句话对学员是噪音，对支持是无信息。
extension AudioEngineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "无法启动麦克风采集，请检查麦克风权限或输入设备后重试"
        case .audioSessionConflict:
            return "音频会话被系统占着，暂时无法开始练习，请稍后重试"
        case .audioSessionClaimFailed(let failure):
            return failure.errorDescription
        }
    }

    /// 进日志的那一份（学员看不到）。判据用它钉住「细节没丢」。
    var telemetryDetail: String {
        switch self {
        case let .invalidFormat(message), let .audioSessionConflict(message):
            return message
        case let .audioSessionClaimFailed(failure):
            return failure.telemetrySummary
        }
    }
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
