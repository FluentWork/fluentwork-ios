import FluentWorkNetworking
import Foundation
import TGReduxKit

/// 闪测（闪测 / Drill）在 store 里的那一格。
///
/// **它是机器输出的一份快照，不是一个自己会算状态的东西。** `DrillRoundMachine` 要发效应
/// （取题、判定、申诉、定时器），所以它跑在中间件里；写回 store 的只有
/// `.applyRound` —— 与 `speakingRoom.session` / `.applySession` 同一条纪律
/// （reducer 里能跑的只有「把结果收下」）。这样状态仍然只有一处，而机器保持纯函数、可单测。
public struct DrillState: Equatable, Sendable, State {
    public var round: DrillRoundState

    /// 这一轮闪测是从哪次练习会话来的。
    ///
    /// 库里可空（`drill_records.session_id`），所以它不是必填：从某次练习会话打开闪测时带上，
    /// 从入口直接进来就是 `nil`。**由调用方（屏幕）决定**，不在这里猜 —— 猜一个
    /// 「最近一次会话」会让归因在学员没练过的时候指向别人的数据。
    public var sourceSessionID: String?

    public init(round: DrillRoundState = DrillRoundState(), sourceSessionID: String? = nil) {
        self.round = round
        self.sourceSessionID = sourceSessionID
    }

    // MARK: - 给视图读的投影

    public var phase: DrillRoundPhase { round.phase }
    public var current: DrillPrompt? { round.current }
    public var position: Int { round.position }
    public var planned: Int { round.planned }
    public var lastVerdict: DrillVerdict? { round.lastVerdict }
    public var lastAppeal: DrillAppealOutcome? { round.lastAppeal }
    public var lastSubmission: DrillSubmission? { round.lastSubmission }

    /// 「已自动化」的变化量（E4）。结算页要显示的就是它，不是快照里的总数 ——
    /// 学员在这一轮里让几张卡变成自动化，才是这一轮的成果。
    public var automatedDelta: Int { round.automatedDelta }

    public var isSettled: Bool { round.isSettled }
    public var awaitingConfirmation: Bool { round.awaitingConfirmation }
    public var canAppeal: Bool { round.canAppeal }

    public var failureMessage: String? {
        if case let .failed(message) = round.phase { return message }
        return nil
    }

    /// 本轮成功率（E4）。
    ///
    /// 分母是**作答次数**，不是题数：超时与跳过也算一次作答（机器会带着空 `asr_text` 提交，
    /// 服务端照常判定），把它们从分母里摘掉会让成功率虚高 —— 学员卡住的正是那几次。
    /// 一次都没答过时是 `nil`，不是 0：结算页要能区分「一次没答」和「全答错了」。
    public var successRate: Double? {
        guard round.answeredAttempts > 0 else { return nil }
        return Double(round.passedAttempts) / Double(round.answeredAttempts)
    }

    /// 「判定前」要展示给学员的识别文本（E2）。
    ///
    /// 优先用**服务端识别的那一份**（`verdict.asr_text`）：这一屏要回答的是「系统听到的是
    /// 什么」，而那句判定就是照着它下的。服务端没给（老版本或判定未走完）时才退回本地提交的
    /// 那句 —— 宁可展示一个旧读数，也不要空着一屏让学员无从确认。
    public var recognitionText: String? {
        if let fromServer = round.lastVerdict?.asrText, !fromServer.isEmpty {
            return fromServer
        }
        guard let submission = round.lastSubmission, !submission.asrText.isEmpty else { return nil }
        return submission.asrText
    }
}

public enum DrillAction: Equatable, Sendable, Action {
    /// 开始一轮。`sessionID` 是可选的归因来源，见 `DrillState.sourceSessionID`。
    case startTapped(size: Int, sessionID: String?)
    case readinessElapsed(at: Date)
    case answerDeadlineReached
    case answerCaptured(asrText: String, at: Date)
    case skipTapped(at: Date)
    case retryTapped
    case advanceTapped
    case appealTapped
    case exitTapped

    // 下面这些是**服务端回来之后**、由中间件派回去的机器事件。
    case roundLoaded(DrillRound)
    case roundLoadFailed(String)
    case verdictReceived(DrillVerdict)
    case attemptFailed(String)
    case appealResolved(DrillAppealOutcome)

    /// 机器算完的新状态写回 store。中间件的唯一写入口。
    case applyRound(DrillRoundState, sourceSessionID: String?)
}

public let drillReducer: Reducer<DrillState, DrillAction> = { state, action in
    guard case let .applyRound(round, sourceSessionID) = action else { return }
    state.round = round
    state.sourceSessionID = sourceSessionID
}

extension DrillAction {
    /// 这个 action 对应机器里的哪个事件。
    ///
    /// `nil` 表示它是**输出**（`.applyRound`），不该再喂回机器 —— 那样会绕成环。
    /// 逐条列出来而不是用 `rawValue` 或协议：这张表就是「屏幕能做什么」的全部，
    /// 加一条 action 忘了加进这里，编译器不会帮忙，但 `DrillFeatureTests` 里那条
    /// 「每个入口 action 都有对应事件」会红。
    var roundEvent: DrillRoundEvent? {
        switch self {
        case let .startTapped(size, _): .start(size: size)
        case let .readinessElapsed(at): .readinessElapsed(at: at)
        case .answerDeadlineReached: .answerDeadlineReached
        case let .answerCaptured(asrText, at): .answerCaptured(asrText: asrText, at: at)
        case let .skipTapped(at): .skipTapped(at: at)
        case .retryTapped: .retryTapped
        case .advanceTapped: .advanceTapped
        case .appealTapped: .appealTapped
        case .exitTapped: .exitTapped
        case let .roundLoaded(round): .roundLoaded(round)
        case let .roundLoadFailed(message): .roundLoadFailed(message: message)
        case let .verdictReceived(verdict): .verdictReceived(verdict)
        case let .attemptFailed(message): .attemptFailed(message: message)
        case let .appealResolved(outcome): .appealResolved(outcome)
        case .applyRound: nil
        }
    }
}
