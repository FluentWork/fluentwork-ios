import Foundation
import FluentWorkNetworking

public enum DrillRoundPhase: Equatable, Sendable {
    case idle
    case loading
    case empty
    case ready
    case answering
    case judging
    case verdict
    case settled
    case failed(message: String)
}

public struct DrillRoundPolicy: Equatable, Sendable {
    public var roundSize: Int
    public var readinessSeconds: Double
    public var answerSeconds: Double
    public var maxRequeuesPerCard: Int

    public init(
        roundSize: Int = 10,
        readinessSeconds: Double = 1,
        answerSeconds: Double = 5,
        maxRequeuesPerCard: Int = 1
    ) {
        self.roundSize = roundSize
        self.readinessSeconds = readinessSeconds
        self.answerSeconds = answerSeconds
        self.maxRequeuesPerCard = maxRequeuesPerCard
    }
}

public struct DrillSubmission: Equatable, Sendable {
    public let blockID: String
    public let asrText: String
    public let responseMS: Int

    public init(blockID: String, asrText: String, responseMS: Int) {
        self.blockID = blockID
        self.asrText = asrText
        self.responseMS = responseMS
    }
}

public struct DrillRoundState: Equatable, Sendable {
    public var phase: DrillRoundPhase
    public var policy: DrillRoundPolicy
    public var planned: Int
    public var position: Int
    public var queue: [DrillPrompt]
    public var current: DrillPrompt?
    public var answeredAttempts: Int
    public var passedAttempts: Int
    public var automatedDelta: Int
    public var requeues: [String: Int]
    public var unresolved: Set<String>
    public var lastVerdict: DrillVerdict?
    public var lastAppeal: DrillAppealOutcome?
    public var lastSubmission: DrillSubmission?
    public var readinessEndedAt: Date?

    public init(policy: DrillRoundPolicy = DrillRoundPolicy()) {
        phase = .idle
        self.policy = policy
        planned = 0
        position = 0
        queue = []
        current = nil
        answeredAttempts = 0
        passedAttempts = 0
        automatedDelta = 0
        requeues = [:]
        unresolved = []
        lastVerdict = nil
        lastAppeal = nil
        lastSubmission = nil
        readinessEndedAt = nil
    }

    public var isSettled: Bool { phase == .settled }
    public var awaitingConfirmation: Bool {
        guard phase == .verdict, let lastVerdict else { return false }
        return lastVerdict.needsConfirmation
    }
    public var canAppeal: Bool {
        guard phase == .verdict, let lastVerdict else { return false }
        guard lastAppeal?.restored != true else { return false }
        return lastVerdict.canAppeal
    }
}

public enum DrillRoundEvent: Equatable, Sendable {
    case start(size: Int)
    case roundLoaded(DrillRound)
    case roundLoadFailed(message: String)
    case readinessElapsed(at: Date)
    case answerDeadlineReached
    case answerCaptured(asrText: String, at: Date)
    case verdictReceived(DrillVerdict)
    case attemptFailed(message: String)
    case retryTapped
    case skipTapped(at: Date)
    case advanceTapped
    case appealTapped
    case appealResolved(DrillAppealOutcome)
    case exitTapped
}

public enum DrillRoundEffect: Equatable, Sendable {
    case fetchRound(size: Int)
    case scheduleReadiness(seconds: Double)
    case scheduleAnswerDeadline(seconds: Double)
    case cancelTimers
    case submitAttempt(blockID: String, asrText: String, responseMS: Int)
    case appeal(recordID: Int64)
    /// 这一题的作答窗口（= 采集窗口）开了：**听一句话**。
    ///
    /// 它与 `scheduleAnswerDeadline` 成对出现，但**是两件事**：那个是「5 秒到点就带空文本提交」
    /// 的兜底，这个是「把这一句转成文字」的正路。少了它，每一题都只走超时那条路 ——
    /// 提交上去的永远是空字符串，而服务端照常判定为失败。
    case captureAnswer(seconds: Double)
    /// 这一轮的采集结束，把音频会话的认领还回去。
    ///
    /// **必须**与第一次 `captureAnswer` 成对：认领不还的后果不是「没有声音」，是**别人的声音
    /// 被关掉**（名册上那个名字等不到归还，此后任何一次归还都判「还有人占着」。
    /// 见 `AudioEngineProtocol.releaseSessionClaim()` 的注释）。
    case stopListening
}
