import FluentWorkCore
import FluentWorkNetworking
import Foundation
import Testing

@testable import FluentWorkUI

/// 屏 04（回顾页）按稿子重排时新增的那些规则。
///
/// 与 `ReviewViewModelTests` 分开：那一份管 D2（丢弃 / 编辑 / 撤回）那些**既有**契约，
/// 这一份管 09-26 稿 屏 04 的三件事 —— **总结条的事实从哪来、先肯定后改进、
/// 首屏只呈现 3 个最高价值点**。
@Suite("回顾页 · 屏 04 的规则")
struct ReviewScreenRebuildTests {

    // MARK: - 装置

    private func json(_ value: String) -> String { value }

    private func makePayload(
        durationSec: Int? = 720,
        rounds: [String] = ["user", "ai", "user", "ai", "user", "ai", "user", "ai", "user"],
        goalMet: Bool = true,
        goalNote: String = "讲清了限流方案的目的与当前进度，没提到预计完成时间。",
        issues: [(quote: String, hint: String)] = [
            ("I will do the cache thing next week.", "下次给个时间点，别只说「下周」。")
        ],
        suggestions: [String] = ["把「我下周弄」换成「我下周三之前给你」。"],
        comparisons: [(user: String, better: String)] = [
            ("I will do the cache thing next week.", "I'll get the caching work wrapped up next week."),
            ("We need to, uh, do it later.", "Let's push the launch to next sprint."),
            ("I am blocked on the API review.", "I'm blocked on the API review."),
            ("I think maybe we can try that.", "I'd suggest we try that."),
            ("Maybe it is not a good idea.", "I'm not sure that's the right call."),
        ],
        refineBlockCount: Int = 4,
        refineCardCount: Int = 3,
        /// 服务端在 `overview` 里报的条数。默认与列表一致；**故意报得更多**用来钉
        /// 「屏幕上显示的是真有的条数，不是服务端那个计数」。
        reportedIssueCount: Int? = nil,
        reportedSuggestionCount: Int? = nil
    ) throws -> ReviewReadyPayload {
        let transcript = rounds.enumerated()
            .map { index, speaker in
                json(#"{"seq":\#(index + 1),"speaker":"\#(speaker)","text":"turn \#(index + 1)"}"#)
            }
            .joined(separator: ",")
        let issueJSON = issues
            .map { json(#"{"type":"grammar","original_quote":"\#($0.quote)","hint":"\#($0.hint)"}"#) }
            .joined(separator: ",")
        let suggestionJSON = suggestions
            .map { json(#"{"text":"\#($0)"}"#) }
            .joined(separator: ",")
        let comparisonJSON = comparisons
            .map { json(#"{"user":"\#($0.user)","better":"\#($0.better)"}"#) }
            .joined(separator: ",")
        let cardJSON = (0..<refineCardCount)
            .map { index in
                json(
                    #"{"intent_zh":"意图 \#(index)","expression_en":"Block \#(index)","anchor_user_said":"said \#(index)","scene_tag":"standup","function_tag":"commit"}"#
                )
            }
            .joined(separator: ",")
        let blockJSON = (0..<refineBlockCount)
            .map { index in
                json(
                    #"{"intent_zh":"块 \#(index)","expression_en":"Block \#(index)","anchor_user_said":"said \#(index)","scene_tag":"standup","function_tag":"commit"}"#
                )
            }
            .joined(separator: ",")
        let duration = durationSec.map(String.init) ?? "null"

        let payload = json(
            """
            {
              "generator":"ark-review-refine-v1",
              "status":"ready",
              "duration_sec":\(duration),
              "transcript":[\(transcript)],
              "overview":{
                "goal_achievement":{"met":\(goalMet),"note":"\(goalNote)"},
                "issue_count":\(reportedIssueCount ?? issues.count),
                "suggestion_count":\(reportedSuggestionCount ?? suggestions.count),
                "comparison_count":\(comparisons.count)
              },
              "evaluation":[],
              "dual_column":[\(comparisonJSON)],
              "refine_cards":[\(cardJSON)],
              "review":{
                "goal_achievement":{"met":\(goalMet),"note":"\(goalNote)"},
                "issues":[\(issueJSON)],
                "suggestions":[\(suggestionJSON)],
                "comparisons":[\(comparisonJSON)]
              },
              "refine":{"blocks":[\(blockJSON)]}
            }
            """
        )
        return try JSONDecoder().decode(ReviewReadyPayload.self, from: Data(payload.utf8))
    }

    private func state(
        payload: ReviewReadyPayload,
        accepted: Set<String> = [],
        discarded: Set<String> = []
    ) -> ReviewState {
        ReviewState(
            sessionID: "s-1",
            phase: .ready,
            payload: payload,
            acceptedRefineCardIDs: accepted,
            discardedRefineCardIDs: discarded
        )
    }

    private func model(_ payload: ReviewReadyPayload) -> ReviewViewModel {
        ReviewViewModel.make(from: state(payload: payload))
    }

    // MARK: - 总结条

    /// 三个事实各有出处；**缺一项就少一项**，不拿 0 去占位。
    ///
    /// 「0 回合」「+0 新增话术块」把「没有这一项」说成「这一项是零」，而这两件事
    /// 对学员的意思完全不同（一个是没练，一个是没提炼出东西）。
    @Test func 总结条缺一项就少一项() throws {
        let full = model(try makePayload())
        #expect(full.summary?.facts == ["12 分钟", "5 回合", "+4 新增话术块"], "实际：\(full.summary?.facts ?? [])")

        let noDuration = model(try makePayload(durationSec: nil))
        #expect(noDuration.summary?.facts.contains { $0.contains("分钟") } == false)

        let noRounds = model(try makePayload(rounds: []))
        #expect(noRounds.summary?.facts.contains { $0.contains("回合") } == false)

        let noBlocks = model(try makePayload(refineBlockCount: 0, refineCardCount: 0))
        #expect(noBlocks.summary?.facts.contains { $0.contains("新增话术块") } == false)
    }

    /// 「回合」数是**学员自己说了几轮**，不是转录的总行数 —— AI 的话不算学员的回合。
    @Test func 回合数是学员自己的轮数() throws {
        let payload = try makePayload(rounds: ["user", "ai", "user", "ai", "user"])
        let facts = model(payload).summary?.facts ?? []

        #expect(facts.contains("3 回合"), "转录 5 行、学员说 3 轮，实际：\(facts)")
        #expect(facts.contains("5 回合") == false, "把 AI 的话也算成学员的回合了")
    }

    /// 时长取整到分钟，**下限 1 分钟**：说了 20 秒也发生过。
    @Test func 时长取整且下限是一分钟() throws {
        func duration(_ seconds: Int) throws -> String? {
            model(try makePayload(durationSec: seconds)).summary?.facts.first { $0.contains("分钟") }
        }

        // 先把结果取出来再断言：`#expect` 的表达式里不能带 `try`（宏展开成非 throwing 的闭包）。
        let twelve = try duration(720)
        let ten = try duration(600)
        let ninety = try duration(90)
        let twenty = try duration(20)
        let zero = try duration(0)

        #expect(twelve == "12 分钟")
        #expect(ten == "10 分钟")
        #expect(ninety == "2 分钟", "90 秒四舍五入到 2 分钟")
        #expect(twenty == "1 分钟", "20 秒是一次真实的练习，不该写成 0 分钟")
        #expect(zero == nil, "0 秒说明没测出时长，不是「0 分钟」")
    }

    // MARK: - 先肯定后改进

    /// 目标达成**跟随服务端的 `met`**，不在客户端重新判断一次。
    @Test func 目标达成跟随服务端() throws {
        let met = model(try makePayload(goalMet: true)).goal
        let missed = model(try makePayload(goalMet: false)).goal

        #expect(met?.isMet == true)
        #expect(met?.headline == "目标达成")
        #expect(missed?.isMet == false)
        #expect(
            missed?.headline.contains("达成") == false,
            "没达成却写着「\(missed?.headline ?? "")」—— 这是这一屏最不该撒的谎"
        )
        #expect(met?.note.isEmpty == false, "那句话（讲清了什么、没提到什么）要带上")
    }

    // MARK: - 首屏只呈现 3 个最高价值点

    /// 三条节各自**只给一条 top**，其余进 `remaining`；合起来与产出同序同数。
    ///
    /// 稿子的原话：「首屏默认只呈现 3 个最高价值点 —— 1 条最响亮的双栏对照、1 个最值得改的问题、
    /// 1 条可复用建议，其余收进『查看全部』」。
    @Test func 三条节各自只给一条且其余进查看全部() throws {
        let model = model(try makePayload())
        let comparison = try #require(model.comparisonSection)
        let issue = try #require(model.issueSection)
        let suggestion = try #require(model.suggestionSection)

        #expect(comparison.remaining.count == 4, "5 条对照里首屏给 1 条")
        #expect(issue.remaining.isEmpty, "只有 1 条问题时没有「其余」")
        #expect(suggestion.remaining.isEmpty)

        // 顺序不能变：top 是最值得改的那一条，就是产出里的第一条。
        let payload = try makePayload()
        #expect(comparison.top.userText == payload.dualColumn[0].user)
        #expect(comparison.remaining.map(\.userText) == payload.dualColumn.dropFirst().map(\.user))
        #expect(comparison.counterText == "1 / 5", "稿子画的是「1 / 5」")
        #expect(comparison.moreButtonTitle == "查看其余 4 条对照")
    }

    /// 只有一条时**不给「查看全部」** —— 一个点了没反应的按钮比没有按钮更糟。
    @Test func 只有一条时不给查看全部() throws {
        let single = try makePayload(
            issues: [("I do it tomorrow.", "下次用 will。")],
            comparisons: [("I do it tomorrow.", "I'll do it tomorrow.")]
        )
        let model = model(single)

        #expect(model.comparisonSection?.moreButtonTitle == nil)
        #expect(model.issueSection?.moreButtonTitle == nil)
        #expect(model.comparisonSection?.counterText == "1 / 1")
    }

    /// 计数写的是**屏幕上真有的条数**，不是服务端那个 `issue_count`。
    ///
    /// 服务端报 9 条而 `review.issues` 只给了 2 条时（截断，或者两个字段本来就不同源），
    /// 计数必须跟着**列得出来的那 2 条**走：否则学员点开「查看全部」会去找那 7 条不存在的，
    /// 而「查看全部 9 条」这个承诺是这一屏唯一能兑现的东西。
    @Test func 计数与实际列出的条数一致() throws {
        let payload = try makePayload(
            issues: [("a", "hint a"), ("b", "hint b")],
            suggestions: ["s1"],
            reportedIssueCount: 9,
            reportedSuggestionCount: 7
        )
        let model = ReviewViewModel.make(from: state(payload: payload))

        #expect(model.issueCountText == "问题清单 2 条", "服务端报的是 9 条，但列得出的是 2 条")
        #expect(model.suggestionCountText == "提高建议 1 条")
        #expect(model.issueSection?.remaining.count == 1, "2 条问题：首屏 1 条 + 其余 1 条")
    }

    /// 一条都没有的那一类**不显示计数**（「问题清单 0 条」是在报告一件没发生的事）。
    @Test func 零条时不显示计数() throws {
        let model = model(try makePayload(issues: [], suggestions: []))

        #expect(model.issueCountText == nil)
        #expect(model.suggestionCountText == nil)
        #expect(model.issueSection == nil)
        #expect(model.suggestionSection == nil)
    }

    // MARK: - 炼化：新增与待入库是两件事

    /// 「+N 新增话术块」是**产出**，「M 个待入库」是**进度**：入库之后前者不变、后者减少。
    @Test func 入库之后新增不变而待入库减少() throws {
        let payload = try makePayload(refineBlockCount: 4, refineCardCount: 3)
        let before = ReviewViewModel.make(from: state(payload: payload))
        #expect(before.summary?.facts.contains("+4 新增话术块") == true)
        #expect(before.pendingRefineText == "3 个待入库")

        let key = try #require(payload.refineCards.first?.id)
        let after = ReviewViewModel.make(from: state(payload: payload, accepted: [key]))
        #expect(
            after.summary?.facts.contains("+4 新增话术块") == true,
            "入库改变了「这次提炼出多少」—— 那是产出，不该跟着变"
        )
        #expect(after.pendingRefineText == "2 个待入库")
    }

    /// 全部入库之后「待入库」这一项就没了（不是「0 个待入库」）。
    ///
    /// 而**卡片本身仍然留在屏幕上**，带着「已入库」的标记 —— 所以「待入库」必须按
    /// `isAccepted` 数，不能拿张数当进度（否则点完「全部入库」这个数一个都不减）。
    @Test func 全部入库后不再显示待入库() throws {
        let payload = try makePayload(refineCardCount: 2)
        let all = Set(payload.refineCards.map(\.id))
        let model = ReviewViewModel.make(from: state(payload: payload, accepted: all))

        #expect(model.pendingRefineText == nil)
        #expect(model.refineCards.count == 2, "入库是「留在屏上带标记」，不是「从屏上消失」")
        // 用 `filter` 而不是 `allSatisfy`：`#expect` 的宏会把 `allSatisfy` 的闭包
        // 当成 throwing 函数（`call can throw, but it is not marked with 'try'`）。
        let notAccepted = model.refineCards.filter { !$0.isAccepted }
        let stillEditable = model.refineCards.filter { $0.canEdit || $0.canDiscard }
        #expect(notAccepted.isEmpty)
        #expect(stillEditable.isEmpty, "入库之后改与丢两个入口都该撤掉")
    }

    // MARK: - 差异标注真的挂上了

    /// 双栏对照里的两侧都带着**词级片段**，而且拼回来等于原文。
    @Test func 对照挂着词级差异片段() throws {
        let payload = try makePayload(
            comparisons: [("I will do the cache thing next week.", "I'll get the caching work wrapped up next week.")]
        )
        let row = try #require(model(payload).comparisonSection?.top)

        #expect(row.userSegments.map(\.text).joined() == row.userText)
        #expect(row.betterSegments.map(\.text).joined() == row.betterText)
        #expect(row.betterSegments.contains { $0.isChanged }, "一句都不一样却一个词都没标")
        #expect(
            row.betterSegments.contains { !$0.isChanged },
            "整句都被标了 —— 全标等于没标"
        )
    }
}
