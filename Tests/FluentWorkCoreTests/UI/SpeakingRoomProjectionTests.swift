import FluentWorkCore
import TGReduxKitTesting
import Testing

@testable import FluentWorkUI

/// `SpeakingRoomViewModel.make(from:usesAutoVAD:)` —— 说的房间的投影。
///
/// 这个文件存在的理由：投影此前是 `HostRootView` 里的一个 `private func`，住在 app
/// target，而 **app target 没有测试 target** —— 门禁腿 2 对它的验证到「能编译」为止。
/// 于是「state 里有一个维度、屏幕上读的是另一个来源」这类缺陷在结构上没人看得见
/// （回顾页刚栽过一次，见 `ReviewProjection`）。
@Suite("说的房间的投影")
struct SpeakingRoomProjectionTests {

    /// 用 **reducer** 造状态，而不是手搓一个 state 字面量。
    ///
    /// 手搓只能证明「我写的这个输入会出问题」；走 reducer 才能证明**这条路径真的能造出
    /// 那个输入** —— 崩的是真实可达的状态，不是一个假想的状态。
    ///
    /// 最后一条 AI 回复不是装饰：时间线里**必须两种说话人都在**，否则「谁说的」这条映射
    /// 没有判别力 —— 把 `isUser` 写死成 `true` 也能通过。第一次做这条变异时正是这样溜过去的。
    private func roomWithThreeHits() -> SpeakingRoomState {
        let store = TestStore(initialState: AppState.initial, reducer: appReducer)
        store.send(.speakingRoom(.userTurnStarted(turnID: "turn-1")))
        // 两条「只有 badge」的命中：reducer 的去重键是 `(badge, phraseBlockID)`
        // （`SpeakingRoomFeature.swift:293-297`），所以 badge 不同、`phraseBlockID`
        // 都是 nil 时**两条都会被收下**。
        store.send(.speakingRoom(.badgeHit(badge: "语法提示")))
        store.send(.speakingRoom(.badgeHit(badge: "流利度")))
        store.send(.speakingRoom(.badgeHit(badge: "地道表达", phraseBlockID: "block-1")))
        store.send(.speakingRoom(.aiTurnTextDelta(text: "Nice work.", turnID: "turn-1")))
        return store.state.speakingRoom
    }

    /// **同一轮里的每个提示必须有唯一的身份。**
    ///
    /// 视图在 `ForEach(row.hits)`（`SpeakingRoomView.swift:618`）里用 `hit.id` 做身份，
    /// 而重复身份在 SwiftUI 里是**未定义行为** —— 不是「画得难看」，是行数不定、点击落到
    /// 别的行上。
    ///
    /// 旧拼法 `"\(phraseBlockID ?? "badge")-\(turnUUID)"` 恰好会撞：两条只有 badge 的
    /// 命中来自同一轮，`phraseBlockID` 都是 nil，于是拿到**同一个 id**。
    @Test func 每一轮里的每个提示都有唯一身份() {
        let state = roomWithThreeHits()
        let model = SpeakingRoomViewModel.make(from: state, usesAutoVAD: false)

        let ids = model.timeline.flatMap { $0.hits.map(\.id) }
        #expect(ids.count == 3, "这一轮应该有 3 条命中，实际 \(ids)")
        #expect(
            Set(ids).count == 3,
            "提示的身份重复了 —— SwiftUI 的 ForEach 拿到重复 id：\(ids)"
        )
        // 两个转发字段也要钉住：不钉的话「badge 传空串」这种变异会因为 id 仍然唯一而溜过去，
        // 而屏幕上的标签就空了。
        #expect(model.timeline[0].hits.map(\.badge) == ["语法提示", "流利度", "地道表达"])
        #expect(model.timeline[0].hits.map(\.phraseBlockID) == [nil, nil, "block-1"])
    }

    /// 身份要**稳定**：同一份 state 投影两次，id 必须逐字相同。
    ///
    /// 加一个自增计数器就能「保证唯一」，但那会让每次投影都换一批 id，等于每帧重建所有行
    /// —— 表现是列表闪、动画断。所以唯一性和稳定性要一起钉。
    @Test func 提示的身份在两次投影之间是稳定的() {
        let state = roomWithThreeHits()
        let first = SpeakingRoomViewModel.make(from: state, usesAutoVAD: false)
        let second = SpeakingRoomViewModel.make(from: state, usesAutoVAD: false)

        #expect(first.timeline == second.timeline)
    }

    /// 时间线的每一行：谁说的、是不是还在听、正文。
    ///
    /// `isListening` 只看 `status`，而不是猜相位 —— `userTurnStarted` 那一行的文案是
    /// 「正在转写…」（人已经说完了），状态却仍是 `.listening`，因为
    /// `serverASRReceived` 靠这个 case 名找到它要替换的那一行。
    ///
    /// **两种说话人都要断言**：只有用户行时，「谁说的」这条映射没有判别力（见 fixture 注释）。
    @Test func 时间线区分说话人并保留正在转写的那一行() throws {
        let state = roomWithThreeHits()
        let model = SpeakingRoomViewModel.make(from: state, usesAutoVAD: false)

        #expect(model.timeline.count == 2, "一轮用户 + 一轮 AI，实际 \(model.timeline.count)")

        let userRow = try #require(model.timeline.first)
        #expect(userRow.isUser)
        #expect(userRow.isListening)
        #expect(userRow.text == "正在转写…")
        #expect(userRow.id == state.timeline[0].id.uuidString)

        let aiRow = try #require(model.timeline.last)
        #expect(aiRow.isUser == false, "AI 那一行被当成了用户说的")
        #expect(aiRow.isListening == false, "AI 那一行被标成了「正在听」")
        #expect(aiRow.text == "Nice work.")
    }

    /// **`usesAutoVAD` 由调用方给，不由房间状态推。**
    ///
    /// 它来自 feature flag（`AppState.usesVoiceVadAuto`），不在 `SpeakingRoomState` 里 ——
    /// 投影以前在 Host 里直接读 `store.state`，那正是「函数签名说它只需要房间状态、实际上
    /// 还要根状态」的那种耦合。把输入提到签名上，跨状态依赖就变成看得见的。
    @Test func 自动断句开关是外部输入而不是房间状态() {
        let state = roomWithThreeHits()

        let tapToTalk = SpeakingRoomViewModel.make(from: state, usesAutoVAD: false)
        let alwaysListening = SpeakingRoomViewModel.make(from: state, usesAutoVAD: true)

        #expect(tapToTalk.usesAutoVAD == false)
        #expect(alwaysListening.usesAutoVAD == true)
        // 除了这一个开关，两份模型必须逐字相同 —— 否则说明它偷偷改了别的东西。
        #expect(tapToTalk.timeline == alwaysListening.timeline)
        #expect(tapToTalk.phase == alwaysListening.phase)
    }

    /// 空房间投影成空时间线，而不是崩掉或缺一行。
    @Test func 空房间投影成空时间线() {
        let model = SpeakingRoomViewModel.make(from: SpeakingRoomState(), usesAutoVAD: false)

        #expect(model.timeline.isEmpty)
        #expect(model.phase == .idle)
        #expect(model.liveTranscript.isEmpty)
    }

    /// 失败原因与救助提示都要跟着走 —— 这两个维度以前只在 Host 里被读过。
    @Test func 失败原因与救助提示都要传到屏幕上() {
        let state = SpeakingRoomState(
            phase: .failed,
            failureReason: "连接中断",
            isRescueHintDue: true
        )
        let model = SpeakingRoomViewModel.make(from: state, usesAutoVAD: false)

        #expect(model.failureReason == "连接中断")
        #expect(model.phase == .failed)
        // `isRescueHintAvailable` 是 `isRescueHintDue && session.awaitsUserTurn` 的合取 ——
        // 失败态下不该提示学员「接着说吧」。
        #expect(model.isRescueHintAvailable == false)
    }
}
