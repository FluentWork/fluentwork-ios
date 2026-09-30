import FluentWorkCore
import FluentWorkNetworking
import Foundation
import Testing
@testable import FluentWorkUI

// MARK: - 投影本身

/// 四个相位照抄，不多不少。
@Test func theFourReviewPhasesMapToTheFourViewPhases() {
    let cases: [(ReviewScreenPhase, ReviewViewPhase)] = [
        (.idle, .idle), (.loading, .loading), (.pending, .pending),
        (.ready, .ready), (.failed, .failed),
    ]
    for (domain, view) in cases {
        var state = ReviewState()
        state.phase = domain
        #expect(ReviewViewModel.make(from: state).phase == view, "\(domain) 映成了别的")
    }
}

/// 还没拿到产出时是**空的列表**，不是崩、也不是假数据。
@Test func anEmptyPayloadProjectsToEmptyLists() {
    let model = ReviewViewModel.make(from: ReviewState())

    #expect(model.overview == nil)
    #expect(model.transcript.isEmpty)
    #expect(model.dualColumn.isEmpty)
    #expect(model.refineCards.isEmpty)
    #expect(model.discardedRefineCards.isEmpty)
}

// MARK: - D2：丢弃与编辑必须到得了屏幕

/// **屏幕上留下的是「可见的那几张」，不是服务端给的全部。**
///
/// 这一条是本文件的**存在理由**。投影层原本住在 `App/FluentWorkHost` 里，而那里是 app target、
/// 没有测试 target —— 于是 D2 上线之后，`state.visibleRefineCards` 有了、投影还在读
/// `payload.refineCards`，**丢弃在屏幕上完全不生效**，而全仓 796 条判据一条都看不到。
@Test func theCardsOnScreenAreTheVisibleOnesNotTheRawPayload() throws {
    let payload = try makePayload()
    var state = ReviewState()
    state.phase = .ready
    state.payload = payload

    #expect(ReviewViewModel.make(from: state).refineCards.count == 2)

    let discardedKey = try #require(payload.refineCards.first?.id)
    state.discardedRefineCardIDs = [discardedKey]

    let model = ReviewViewModel.make(from: state)
    #expect(model.refineCards.count == 1, "被丢掉的那张还在屏幕上")
    #expect(!model.refineCards.contains { $0.id == discardedKey })
    #expect(
        state.payload?.refineCards.count == 2,
        "产出本身被改写了 —— 撤回就只剩「重新拉一次回顾」这条路"
    )
}

/// 改过的卡：屏幕上是**改后的字**，并且明确标出「这一张动过」。
@Test func anEditedCardShowsTheEditedWordsAndSaysSo() throws {
    let payload = try makePayload()
    let card = try #require(payload.refineCards.first)
    var state = ReviewState()
    state.phase = .ready
    state.payload = payload
    // `RefineCard` 没有跨模块可用的逐字段构造器（只有 `init(from:)`），所以用副本改。
    var draft = card
    draft.expressionEN = "I'll circle back with the team tomorrow."
    state.refineCardDrafts[card.id] = draft

    let row = try #require(ReviewViewModel.make(from: state).refineCards.first)

    #expect(row.expressionEN == "I'll circle back with the team tomorrow.")
    #expect(row.isEdited, "改过之后没有标记 —— 学员看不出这一张是自己动过的")
    #expect(row.intentZH == card.intentZH, "没改的字段被顺手带偏了")
}

/// **稳定键在编辑之后必须还是原来那个。**
///
/// 这是最容易踩空的地方：`RefineCard.id` 是内容派生的，改一个字它就换一个。视图拿
/// 「编辑后的卡自己的 id」回派（入库 / 再编辑 / 撤回），改完第一个字符就再也找不到自己 ——
/// 而这条路上任何地方都不会报错，学员只会发现按钮失灵。
@Test func theRowKeySurvivesAnEdit() throws {
    let payload = try makePayload()
    let card = try #require(payload.refineCards.first)
    var state = ReviewState()
    state.phase = .ready
    state.payload = payload
    var draft = card
    draft.expressionEN = "Edited."
    draft.anchorUserSaid = "Edited too."
    state.refineCardDrafts[card.id] = draft

    let row = try #require(ReviewViewModel.make(from: state).refineCards.first)

    #expect(row.id == card.id, "行身份被编辑改掉了：\(row.id)")
    #expect(row.expressionEN == "Edited.")
}

/// 在途与已入库两个标记来自 state，而且是按**稳定键**查的。
@Test func inFlightAndAcceptedFlagsComeFromTheState() throws {
    let payload = try makePayload()
    let first = try #require(payload.refineCards.first?.id)
    let second = try #require(payload.refineCards.last?.id)
    var state = ReviewState()
    state.phase = .ready
    state.payload = payload
    // 先改第一张：这样 `entry.card.id`（内容派生）与 `entry.key`（原卡 id）**不再相等** ——
    // 两个标记若按前者查（一个很容易写出的错），下面就红。
    var draft = try #require(payload.refineCards.first)
    draft.expressionEN = "Edited."
    state.refineCardDrafts[first] = draft
    state.acceptingRefineCardIDs = [first]
    state.acceptedRefineCardIDs = [second]

    let rows = ReviewViewModel.make(from: state).refineCards

    #expect(rows.first { $0.id == first }?.isAccepting == true)
    #expect(rows.first { $0.id == first }?.isAccepted == false)
    #expect(rows.first { $0.id == second }?.isAccepted == true)
    #expect(rows.first { $0.id == second }?.isAccepting == false)
}

/// **被丢掉的那几张仍然读得到** —— 否则「撤回」这个动作在屏幕上没有入口。
///
/// 数据层有 `restoreRefineCardTapped`，而 `visibleRefineCards` 恰好把它们滤掉了：
/// 没有这一条投影，撤回就是一条**没有入口的动作**，而判据只看得见 reducer，
/// 会一直绿着说「撤回可用」。
@Test func discardedCardsAreStillReachableSoUndoHasASource() throws {
    let payload = try makePayload()
    let discardedKey = try #require(payload.refineCards.first?.id)
    var state = ReviewState()
    state.phase = .ready
    state.payload = payload
    state.discardedRefineCardIDs = [discardedKey]

    let model = ReviewViewModel.make(from: state)

    #expect(model.refineCards.count == 1)
    let undone = try #require(model.discardedRefineCards.first)
    #expect(model.discardedRefineCards.count == 1)
    #expect(undone.id == discardedKey, "撤回列表里的身份也得是稳定键")
    #expect(
        undone.expressionEN == payload.refineCards.first?.expressionEN,
        "撤回列表要能显示它原来是哪一句"
    )
}

/// 一个都没丢时撤回列表是空的（不是「全部卡」）。
@Test func nothingDiscardedMeansNoUndoEntries() throws {
    let payload = try makePayload()
    var state = ReviewState()
    state.phase = .ready
    state.payload = payload

    #expect(ReviewViewModel.make(from: state).discardedRefineCards.isEmpty)
}

/// 错误信息按来源分开：炼化入库失败与整屏失败不是同一件事，屏上呈现也不同。
@Test func theTwoErrorMessagesStayApart() {
    var state = ReviewState()
    state.phase = .ready
    state.acceptErrorMessage = "入库失败"
    state.lastErrorMessage = "回顾生成失败"

    let model = ReviewViewModel.make(from: state)

    #expect(model.refineErrorMessage == "入库失败")
    #expect(model.errorMessage == "回顾生成失败")
}

// MARK: - 装置

private func makePayload() throws -> ReviewReadyPayload {
    let json = """
        {
          "generator":"ark-review-refine-v1",
          "status":"ready",
          "duration_sec":600,
          "transcript":[
            {"seq":1,"speaker":"user","text":"I do it tomorrow."}
          ],
          "overview":{"goal_achievement":{"met":true,"note":"Met"},"issue_count":1,"suggestion_count":1,"comparison_count":1},
          "evaluation":[{"layer":"goal","title":"Goal","content":{"met":true}}],
          "dual_column":[{"user":"I do it tomorrow.","better":"I'll do it tomorrow."}],
          "refine_cards":[
            {"intent_zh":"说明下一步","expression_en":"I'll do it tomorrow.","anchor_user_said":"I do it tomorrow.","scene_tag":"standup","function_tag":"commit"},
            {"intent_zh":"报告阻塞","expression_en":"I'm blocked on the API review.","anchor_user_said":"I am blocked","scene_tag":"standup","function_tag":"report"}
          ],
          "review":{
            "goal_achievement":{"met":true,"note":"Met"},
            "issues":[{"type":"grammar","original_quote":"I do it tomorrow.","hint":"Use future tense."}],
            "suggestions":[{"text":"Use will + verb."}],
            "comparisons":[{"user":"I do it tomorrow.","better":"I'll do it tomorrow."}]
          },
          "refine":{"blocks":[]}
        }
        """
    return try JSONDecoder().decode(ReviewReadyPayload.self, from: Data(json.utf8))
}
