import FluentWorkCore
import Foundation

/// 闪测三屏（05 训练卡流 / 06 判定与申诉 / 07 结算）的**屏级模型**。
///
/// 三屏共用一台机器（`DrillRoundMachine`），所以共用一份投影 —— 分成三份会让
/// 「同一张卡在三屏里的名字」有三个去处。
///
/// 这一份里最要紧的不是字段，是**字段的顺序与条件**：
/// 稿子把「识别文本在前、判定在后」列为 E2 的 P0（顺序反了，人会直接进入防御），
/// 所以顺序在这里是**用类型表达的**：`asrText` 与判定文案是两个字段，
/// 而且没有识别文本时**判定文案不许出现**。
public enum DrillScreen: Equatable, Sendable {
    case loading
    /// 语料不足：**不许空跑**（没有话术块的闪测没有可考核的对象）。给一个「去练习」的出口。
    case empty
    case cardStream
    case verdict
    case settlement
    case failed(message: String)
}

public struct DrillViewModel: Equatable, Sendable {

    public struct Card: Equatable, Sendable {
        /// 要说什么（中文意图）—— 学员的任务是把它说成英文。
        public var intentZH: String
        public var position: Int
        public var planned: Int
        public var isAnswering: Bool
        public var answerSeconds: Double

        public init(
            intentZH: String,
            position: Int,
            planned: Int,
            isAnswering: Bool,
            answerSeconds: Double
        ) {
            self.intentZH = intentZH
            self.position = position
            self.planned = planned
            self.isAnswering = isAnswering
            self.answerSeconds = answerSeconds
        }
    }

    /// 判定这一屏的样子。
    ///
    /// ⚠️ `asrText` 与 `headline`/`reason` **必须同时为真或同时为空**：
    /// 只有判定没有识别文本，等于让学员先看到结果 —— 而那正是 E2 要防的事。
    public struct Verdict: Equatable, Sendable {
        public var asrText: String
        public var headline: String
        public var reason: String
        public var passed: Bool
        /// 申诉入口（「我说的是对的」）：紧贴识别文本，不用翻页、不用长按。
        public var canAppeal: Bool
        public var appealTitle: String

        public init(
            asrText: String,
            headline: String,
            reason: String,
            passed: Bool,
            canAppeal: Bool,
            appealTitle: String
        ) {
            self.asrText = asrText
            self.headline = headline
            self.reason = reason
            self.passed = passed
            self.canAppeal = canAppeal
            self.appealTitle = appealTitle
        }
    }

    public struct Settlement: Equatable, Sendable {
        public var answered: Int
        public var passed: Int
        public var automatedDelta: Int
        /// 这轮没能说清的（它们会回到队列里，不是失败）。
        public var unresolvedCount: Int

        public init(answered: Int, passed: Int, automatedDelta: Int, unresolvedCount: Int) {
            self.answered = answered
            self.passed = passed
            self.automatedDelta = automatedDelta
            self.unresolvedCount = unresolvedCount
        }
    }

    public var screen: DrillScreen
    public var card: Card?
    public var verdict: Verdict?
    public var settlement: Settlement?

    /// 空态的两句话：**说清为什么没有，并给一条出路**。
    public var emptyTitle: String
    public var emptyDetail: String
    public var emptyCTATitle: String
}

extension DrillViewModel {
    /// 申诉那条按钮的文案。**只有一句**，而且是第一人称 ——
    /// 稿子：它紧贴识别文本，不需要翻页或长按。
    public static let appealTitle = "我说的是对的"

    public static func make(from state: DrillRoundState) -> DrillViewModel {
        var model = DrillViewModel(
            screen: screen(for: state),
            card: nil,
            verdict: nil,
            settlement: nil,
            emptyTitle: "语料库还是空的",
            // 空态**不许空跑**：没有话术块的闪测没有可考核的对象。
            emptyDetail: "闪测考的是你自己攒下的表达。先去完成一次「说」，攒下第一句话术块。",
            emptyCTATitle: "去练习"
        )

        if let current = state.current,
           state.phase == .ready || state.phase == .answering || state.phase == .loading {
            model.card = Card(
                intentZH: current.intentZH,
                position: state.position + 1,
                planned: state.planned,
                isAnswering: state.phase == .answering,
                answerSeconds: state.policy.answerSeconds
            )
        }

        if state.phase == .verdict || state.phase == .settled {
            model.verdict = verdict(for: state)
        }

        if state.phase == .settled {
            model.settlement = Settlement(
                answered: state.answeredAttempts,
                passed: state.passedAttempts,
                automatedDelta: state.automatedDelta,
                unresolvedCount: state.unresolved.count
            )
        }

        return model
    }

    private static func screen(for state: DrillRoundState) -> DrillScreen {
        switch state.phase {
        case .idle, .loading:
            return .loading
        case .empty:
            return .empty
        case .ready, .answering, .judging:
            return .cardStream
        case .verdict:
            return .verdict
        case .settled:
            return .settlement
        case let .failed(message):
            return .failed(message: message)
        }
    }

    /// 判定的投影 —— **顺序这件事在这里落地**。
    ///
    /// 没有识别文本时返回 `nil`：宁可这一屏什么都不给，也不让「判定」单独出现在屏幕上。
    /// 判定中（`.judging`）也返回 `nil`：结果还没出来，先给结论等于催人。
    private static func verdict(for state: DrillRoundState) -> Verdict? {
        guard let rawVerdict = state.lastVerdict else { return nil }

        // 识别文本优先用提交时那份（它是学员刚说的话），判定里带的那份做兜底。
        let asrText = state.lastSubmission?.asrText ?? rawVerdict.asrText
        guard !asrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return Verdict(
            asrText: asrText,
            headline: rawVerdict.pass ? "过了" : "再来一次",
            reason: rawVerdict.judgeReason,
            passed: rawVerdict.pass,
            // 申诉的对象是**识别文本**：没有它就没有「我说的是对的」可申诉的东西。
            // 已判过且记录在案才给入口（`recorded`），否则申诉没有落点。
            canAppeal: rawVerdict.judged && rawVerdict.recorded,
            appealTitle: appealTitle
        )
    }
}
