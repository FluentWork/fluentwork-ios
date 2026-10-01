import FluentWorkCore
import FluentWorkNetworking
import Foundation
import Testing

@testable import FluentWorkUI

/// 闪测三屏的投影。这一组盯的是**顺序与条件** —— 稿子把「识别文本在前、判定在后」
/// 列为 E2 的 P0，而那种错在真机上只表现为「学员忽然不想说了」，很难查。
@Suite("闪测三屏的投影")
struct DrillProjectionTests {

    private func state(_ phase: DrillRoundPhase) -> DrillRoundState {
        var state = DrillRoundState()
        state.phase = phase
        state.planned = 10
        state.position = 2
        state.current = DrillPrompt(blockID: "b-1", intentZH: "说明白缓存为什么这么设计")
        return state
    }

    private func verdict(pass: Bool, asr: String = "the cache thing is fine") -> DrillVerdict {
        DrillVerdict(
            pass: pass,
            judgeReason: "信息点覆盖 2/3",
            judged: true,
            retryable: !pass,
            successStreak: pass ? 2 : 0,
            state: .training,
            nextDueAt: Date(timeIntervalSince1970: 0),
            recorded: true,
            recordID: 7,
            promoted: false,
            asrText: asr
        )
    }

    // MARK: - 空态不许空跑

    @Test func 语料不足时是空态且没有卡() {
        let model = DrillViewModel.make(from: state(.empty))

        #expect(model.screen == .empty)
        #expect(model.card == nil, "空态里却有一张训练卡 —— 没有话术块就没有可考核的对象")
        #expect(model.emptyCTATitle == "去练习", "空态没给出口：学员会卡在一张空屏上")
    }

    // MARK: - 识别文本在前，判定在后（E2 的 P0）

    /// **没有识别文本就不给判定。**
    ///
    /// 稿子原话：识别文本置顶展示，判定结果在后 —— 顺序不能反，先看到结果会让人直接进入防御。
    /// 那么反过来，如果压根没有识别文本，就**不该有判定**（否则屏幕上只剩结论）。
    @Test func 没有识别文本就不出现判定() {
        var emptyASR = state(.verdict)
        emptyASR.lastVerdict = verdict(pass: false, asr: "   ")
        emptyASR.lastSubmission = DrillSubmission(blockID: "b-1", asrText: "", responseMS: 900)

        let model = DrillViewModel.make(from: emptyASR)
        #expect(model.verdict == nil, "只有判定没有识别文本 —— 学员会先看到结果")
    }

    /// 有识别文本时，两样都在，而且识别文本与判定是**分开的字段**
    /// （合在一起就没法保证谁先出现在屏幕上）。
    @Test func 识别文本与判定同时在场() {
        var state = state(.verdict)
        state.lastVerdict = verdict(pass: false)
        state.lastSubmission = DrillSubmission(blockID: "b-1", asrText: "the cache thing", responseMS: 900)

        let model = DrillViewModel.make(from: state)
        let verdict = try! #require(model.verdict)
        #expect(verdict.asrText == "the cache thing")
        #expect(verdict.headline == "再来一次")
        #expect(verdict.reason == "信息点覆盖 2/3")
    }

    /// 提交时那份识别文本**优先于**判定里带的那份：那是学员刚说的话。
    @Test func 优先用提交时的识别文本() {
        var state = state(.verdict)
        state.lastVerdict = verdict(pass: true, asr: "判定里那份")
        state.lastSubmission = DrillSubmission(
            blockID: "b-1", asrText: "我刚刚说的那份", responseMS: 900
        )

        #expect(DrillViewModel.make(from: state).verdict?.asrText == "我刚刚说的那份")
    }

    // MARK: - 申诉紧贴识别文本

    /// 申诉入口是「我说的是对的」——**只有一句，第一人称**，
    /// 而且只在有识别文本、且这次判定真的被记录之后才给。
    @Test func 申诉入口的条件与文案() {
        var appealable = state(.verdict)
        appealable.lastVerdict = verdict(pass: false)
        appealable.lastSubmission = DrillSubmission(blockID: "b-1", asrText: "x", responseMS: 1)

        let verdict = try! #require(DrillViewModel.make(from: appealable).verdict)
        #expect(verdict.canAppeal)
        #expect(verdict.appealTitle == "我说的是对的")
    }

    /// **没记录就别给申诉**：申诉要有落点（一条记录），没有落点的按钮是坏的。
    @Test func 没有记录时不给申诉入口() {
        var state = state(.verdict)
        var recorded = verdict(pass: false)
        recorded = DrillVerdict(
            pass: recorded.pass, judgeReason: recorded.judgeReason, judged: true,
            retryable: recorded.retryable, successStreak: recorded.successStreak,
            state: recorded.state, nextDueAt: recorded.nextDueAt,
            recorded: false, recordID: 0, promoted: false, asrText: recorded.asrText
        )
        state.lastVerdict = recorded
        state.lastSubmission = DrillSubmission(blockID: "b-1", asrText: "x", responseMS: 1)

        #expect(DrillViewModel.make(from: state).verdict?.canAppeal == false)
    }

    // MARK: - 判定中不给结论

    @Test func 判定中不给判定也不给申诉() {
        var judging = state(.judging)
        judging.lastVerdict = verdict(pass: true)
        judging.lastSubmission = DrillSubmission(blockID: "b-1", asrText: "x", responseMS: 1)

        let model = DrillViewModel.make(from: judging)
        #expect(model.screen == .cardStream, "判定中应当还在卡流上")
        #expect(model.verdict == nil, "结果还没出来就先给了结论")
    }

    // MARK: - 卡流与结算

    @Test func 卡流给出第几张与要说什么() {
        let model = DrillViewModel.make(from: state(.answering))
        let card = try! #require(model.card)

        #expect(card.intentZH == "说明白缓存为什么这么设计")
        #expect(card.position == 3, "第三张（position 从 0 数，人从 1 数）")
        #expect(card.planned == 10)
        #expect(card.isAnswering)
    }

    @Test func 结算页的计数() {
        var settled = state(.settled)
        settled.answeredAttempts = 10
        settled.passedAttempts = 8
        settled.automatedDelta = 3
        settled.unresolved = ["b-1", "b-2"]

        let model = DrillViewModel.make(from: settled)
        #expect(model.screen == .settlement)
        let settlement = try! #require(model.settlement)
        #expect(settlement.answered == 10)
        #expect(settlement.passed == 8)
        #expect(settlement.automatedDelta == 3)
        #expect(settlement.unresolvedCount == 2)
    }

    /// 失败态带着原因，不是一片空白。
    @Test func 失败态带原因() {
        let model = DrillViewModel.make(from: state(.failed(message: "网络没通")))
        #expect(model.screen == .failed(message: "网络没通"))
    }
}
