import FluentWorkCore
import FluentWorkNetworking
import Foundation
import Testing

@testable import FluentWorkUI

/// 屏 02 / 03（说的房间）按稿子还原时落在**状态层与投影**上的那些规则。
///
/// 视图重排是另一件事；这一份盯的是「屏幕上那句话是哪来的」：
/// 卡壳点、被打断、第几轮、浮层与气泡谁说话、救援三句。
@Suite("说的房间 · 屏 02/03 的规则")
struct SpeakingRoomScreenRebuildTests {

    // MARK: - 装置

    private func userItem(_ text: String = "Well, we need to… um") -> TurnTimelineItem {
        TurnTimelineItem(turnID: "t-1", speaker: .user, text: text, status: .listening)
    }

    private func aiItem(_ text: String = "So what's the plan for the cache eviction work?") -> TurnTimelineItem {
        TurnTimelineItem(turnID: nil, speaker: .ai, text: text, status: .finalized)
    }

    private func state(
        timeline: [TurnTimelineItem] = [],
        phase: SpeechSessionPhase = .waitingUser,
        userTurnCount: Int = 0,
        liveTranscript: String = "",
        isRescueHintDue: Bool = false
    ) -> SpeakingRoomState {
        var session = SpeechSessionState.initial
        session.phase = phase
        session.userTurnCount = userTurnCount
        return SpeakingRoomState(
            session: session,
            liveTranscript: liveTranscript,
            timeline: timeline,
            isRescueHintDue: isRescueHintDue
        )
    }

    private func creation(
        scene: String? = "standup",
        length: PracticeSessionLength = .standard
    ) -> PracticeCreation {
        PracticeCreation(materialID: "m-1", sceneType: scene, length: length)
    }

    // MARK: - 卡壳点（屏 03）

    /// 救援到点 = 学员卡住了 ⇒ **那一轮**被标成卡壳点。
    ///
    /// 稿子的硬约束写着「不记入失败：用户那句截断的话保留在时间线上并标记为『卡壳点』，
    /// 照常进入 D1 炼化候选 —— 卡壳点正是最该练的东西」。所以它是一条标记，不是删除。
    @Test func 救援到点时把学员那一轮标成卡壳点() {
        var before = state(timeline: [aiItem(), userItem()])
        speakingRoomReducer(&before, .rescueHintBecameDue)

        #expect(before.timeline[1].isStallPoint, "学员卡住的那一句没被标")
        #expect(before.timeline[0].isStallPoint == false, "AI 那一句不该被标成卡壳点")
        #expect(before.timeline[1].text == "Well, we need to… um", "标记不该改写那句话")
    }

    /// 卡壳点按**说话人**往回找，不取 `timeline.last`。
    ///
    /// 真实次序里，静默到点时时间线尾部往往已经多了一条 AI 的占位（提示本身）——
    /// 学员卡住的那句在它**前面**。取 last 会把标记打在提示上。
    @Test func 卡壳点标在学员那一句而不是最后一条() {
        var before = state(timeline: [aiItem(), userItem(), aiItem("给我一个句首骨架：I think the main risk is…")])
        speakingRoomReducer(&before, .rescueHintBecameDue)

        #expect(before.timeline[1].isStallPoint, "应当标在学员那句上")
        #expect(before.timeline[2].isStallPoint == false, "不能标在刚递出去的提示上")
    }

    /// 一条消息都没有时静默到点：不崩、也不凭空造一条。
    @Test func 没有时间线时不标卡壳点() {
        var before = state()
        speakingRoomReducer(&before, .rescueHintBecameDue)

        #expect(before.timeline.isEmpty)
        #expect(before.isRescueHintDue)
    }

    // MARK: - 被打断（屏 02）

    /// `aiSpeaking → recording` 只有一种成因：学员在 AI 还在说的时候开了口。
    @Test func 打断说话中的AI会给它打截断标记() {
        var before = state(timeline: [aiItem()], phase: .aiSpeaking)
        var next = before.session
        next.phase = .recording

        speakingRoomReducer(&before, .applySession(next))

        #expect(before.timeline[0].wasInterrupted, "被学员打断的 AI 气泡没打标记 —— 它看起来像「卡住了」")
    }

    /// 其它相位转移**不该**误标。
    @Test func 其它相位转移不误标打断() {
        // 处理中 → 录音：学员等得不耐烦自己开口，AI 本来就还没说。
        var processing = state(timeline: [aiItem()], phase: .processing)
        var next = processing.session
        next.phase = .recording
        speakingRoomReducer(&processing, .applySession(next))
        #expect(processing.timeline[0].wasInterrupted == false, "AI 还没开口，「打断」无从谈起")

        // 等待中 → 录音：正常开一轮。
        var waiting = state(timeline: [aiItem()], phase: .waitingUser)
        var waitingNext = waiting.session
        waitingNext.phase = .recording
        speakingRoomReducer(&waiting, .applySession(waitingNext))
        #expect(waiting.timeline[0].wasInterrupted == false)
    }

    // MARK: - 顶部栏的事实（屏 02）

    /// 「第 N 轮」＝正在进行的这一轮（已说完的轮数 ＋ 1）。
    @Test func 轮次是已完成的轮数加一() {
        let first = SpeakingRoomViewModel.make(from: state(userTurnCount: 0), usesAutoVAD: false)
        let third = SpeakingRoomViewModel.make(from: state(userTurnCount: 2), usesAutoVAD: false)

        #expect(first.roundText == "第 1 轮")
        #expect(third.roundText == "第 3 轮")
    }

    /// 场景名：**认得出的用词表里的中文标签，认不出的用原值**，都没有就不显示。
    @Test func 场景名认得出用标签认不出用原值() {
        func label(_ scene: String?) -> String? {
            SpeakingRoomViewModel.make(
                from: state(),
                usesAutoVAD: false,
                creation: creation(scene: scene)
            ).sceneLabel
        }

        #expect(label("standup") == "Standup")
        #expect(label("1on1") == "1:1")
        #expect(label("allhands") == "allhands", "认不出的场景不该被折成某个已知的 —— 那是确定但错的")
        #expect(label(nil) == nil)
        #expect(label("") == nil)
    }

    /// 会话时长名两项不同（「标准会话」/「迷你会话」）。
    @Test func 时长名两项不同() {
        let standard = SpeakingRoomViewModel.make(
            from: state(), usesAutoVAD: false, creation: creation(length: .standard)
        ).lengthText
        let mini = SpeakingRoomViewModel.make(
            from: state(), usesAutoVAD: false, creation: creation(length: .mini)
        ).lengthText

        #expect(standard == "标准会话")
        #expect(mini == "迷你会话")
        #expect(standard != mini)
    }

    /// 「用上 N 个」：**一个都没用上时不显示**（写「用上 0 个」是在报告一件没发生的事）。
    @Test func 用上零个时不显示() {
        let none = SpeakingRoomViewModel.make(from: state(), usesAutoVAD: false)
        #expect(none.badgeHitText == nil)

        var hit = state()
        hit.badgeHits = 2
        #expect(SpeakingRoomViewModel.make(from: hit, usesAutoVAD: false).badgeHitText == "用上 2 个")
    }

    // MARK: - 禁止双重展示（屏 02 的第一条易错点）

    /// 录音中：浮层有那句话。
    @Test func 录音时浮层显示实时转写() {
        let model = SpeakingRoomViewModel.make(
            from: state(phase: .recording, liveTranscript: "One thing I want to flag is…"),
            usesAutoVAD: false
        )

        #expect(model.liveTranscriptFloat == "One thing I want to flag is…")
    }

    /// **话音落下后浮层必须为空** —— 同一句话不该同时出现在浮层与气泡里。
    ///
    /// `liveTranscript` 在录音结束后**仍然留着**那句话（服务端转写会写进它，同一句话
    /// 也已经进了气泡）。所以这条判据守的是「浮层无条件读它」这个最省事的写法。
    @Test func 录音结束后浮层不再显示那句话() {
        let spoken = "Yesterday I finished the rate-limit design and got it reviewed."
        var after = state(
            timeline: [userItem(spoken)],
            phase: .processing,
            liveTranscript: spoken
        )
        after.timeline[0].status = .finalized

        let model = SpeakingRoomViewModel.make(from: after, usesAutoVAD: false)

        #expect(model.liveTranscriptFloat == nil, "话音已落，浮层还留着那句话 —— 屏幕上出现了两份同样的字")
        #expect(model.timeline.contains { $0.text == spoken }, "同一句话应当在气泡里")
    }

    /// 录音中但还没听到任何字：浮层不显示（一个空浮层会占着位置闪）。
    @Test func 录音中还没有字时不出浮层() {
        let model = SpeakingRoomViewModel.make(
            from: state(phase: .recording, liveTranscript: "   "),
            usesAutoVAD: false
        )

        #expect(model.liveTranscriptFloat == nil)
    }

    // MARK: - 救援（屏 03）

    /// 救援的三句只在**就绪**时出现，且两句安抚/提示文案各自不同。
    @Test func 救援文案只在就绪时出现() {
        let notYet = SpeakingRoomViewModel.make(from: state(), usesAutoVAD: false)
        #expect(notYet.rescueHeadline == nil, "还没到点就写「已经 3 秒没有听到你」是在抢先说话")

        let due = SpeakingRoomViewModel.make(
            from: state(phase: .waitingUser, isRescueHintDue: true),
            usesAutoVAD: false
        )
        #expect(due.rescueHeadline == "已经 3 秒没有听到你")
        #expect(due.rescueReassurance == "慢一点没关系，这不算失败")
        #expect(due.rescueButtonTitle == "给我点儿提示")
        #expect(due.rescueReassurance != due.rescueButtonTitle)
    }

    /// 救援就绪还要求**轮到学员**（`awaitsUserTurn`）：AI 正在说的时候静默不该递提示。
    @Test func AI说话时不算救援就绪() {
        let model = SpeakingRoomViewModel.make(
            from: state(phase: .aiSpeaking, isRescueHintDue: true),
            usesAutoVAD: false
        )

        #expect(model.isRescueHintAvailable == false)
        #expect(model.rescueHeadline == nil)
    }

    // MARK: - 两个标记

    /// 卡壳点与打断是两件事，文案也必须两样 —— 一个灰签写着「卡壳点」、另一个也写着它，
    /// 是那种在稿子上看不出来、要用眼睛在真机上撞见的错。
    @Test func 两个标记的文案不同且都非空() {
        #expect(SpeakingRoomTimelineRow.stallPointMarker.isEmpty == false)
        #expect(SpeakingRoomTimelineRow.interruptedMarker.isEmpty == false)
        #expect(SpeakingRoomTimelineRow.stallPointMarker != SpeakingRoomTimelineRow.interruptedMarker)
    }

    /// 两个标记**真的到了屏幕上**（投影直通，不是被吞在中间）。
    @Test func 两个标记到得了屏幕() {
        var raw = state(timeline: [aiItem(), userItem()])
        raw.timeline[0].wasInterrupted = true
        raw.timeline[1].isStallPoint = true

        let rows = SpeakingRoomViewModel.make(from: raw, usesAutoVAD: false).timeline

        #expect(rows[0].wasInterrupted)
        #expect(rows[1].isStallPoint)
        #expect(rows[0].isStallPoint == false)
    }
}
