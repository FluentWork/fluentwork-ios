import FluentWorkCore
import FluentWorkNetworking
import Testing

@testable import FluentWorkUI

/// `DailyReadViewModel.make(from:isOffline:)` —— 每日一读的投影。
///
/// 这一份此前是 `HostRootView` 的 `private func`，住在 **app target**（没有测试 target），
/// 门禁对它的验证到「能编译」为止。搬进 `FluentWorkUI` 之后，它才第一次有判据。
@Suite("每日一读的投影")
struct DailyReadProjectionTests {

    private func article(
        body: String = "One two three four five.",
        audioURL: String? = "https://example.test/a.mp3",
        usedBlockIDs: [String] = ["b1", "b2"]
    ) -> DailyRead {
        DailyRead(
            id: "read-1",
            title: "今天的读",
            body: body,
            audioURL: audioURL,
            generator: "gen",
            usedBlockIDs: usedBlockIDs
        )
    }

    /// 骨架屏的规则**只有一份**：投影直通 `DailyReadState.showsSkeleton`，UI 侧不再写第二份。
    ///
    /// 这里曾经是同一条规则的两份写法（Core 按状态相位 `.generating || .idle`、UI 按视图相位
    /// `.idle || .loading`），而 UI 那一份**根本没人读** —— 视图当时直接
    /// `case .idle, .loading` 就走到了骨架屏。两份都长着一副「有东西在读我」的样子。
    ///
    /// 现在只有 Core 那一份，视图读投影直通过来的值。判据留着，守的变成**以后**：
    /// 谁要是在 UI 侧再按相位算一遍，两侧一旦不等它就红。
    @Test func 骨架屏的规则只从state来() {
        let phases: [DailyReadScreenPhase] = [.idle, .generating, .ready, .fallbackPreset, .failed]

        for phase in phases {
            var state = DailyReadState()
            state.phase = phase
            let model = DailyReadViewModel.make(from: state, isOffline: false)

            #expect(
                model.showsSkeleton == state.showsSkeleton,
                "相位 \(phase) 上 UI 侧自己算了一份、且与 state 不一致：视图 \(model.showsSkeleton) / 状态 \(state.showsSkeleton)"
            )
        }
    }

    /// **有内容就不盖骨架** —— 这条和上面那条守的是两件事。
    ///
    /// 上一条只保证「两处相等」。若有人把规则改成「只要不是 `.ready` 就盖」，
    /// `.fallbackPreset` 就会盖上一层骨架，而兜底那一路**是有正文的**：
    /// 学员看到骨架，会以为内容没了。
    @Test func 兜底内容不盖骨架() {
        var fallback = DailyReadState()
        fallback.phase = .fallbackPreset
        #expect(
            DailyReadViewModel.make(from: fallback, isOffline: false).showsSkeleton == false,
            "兜底内容是有正文的，不是「还没好」"
        )

        var ready = DailyReadState()
        ready.phase = .ready
        #expect(DailyReadViewModel.make(from: ready, isOffline: false).showsSkeleton == false)

        // 反向：真正在生成的时候要盖（少了这一半，「恒为 false」也能过）。
        var generating = DailyReadState()
        generating.phase = .generating
        #expect(DailyReadViewModel.make(from: generating, isOffline: false).showsSkeleton)
    }

    /// 五个状态相位映到五个视图相位，一个不少、顺序不错。
    @Test func 五个相位一一对应() {
        let expected: [(DailyReadScreenPhase, DailyReadViewPhase)] = [
            (.idle, .idle),
            (.generating, .loading),
            (.ready, .ready),
            (.fallbackPreset, .fallbackPreset),
            (.failed, .failed),
        ]

        for (state, view) in expected {
            var s = DailyReadState()
            s.phase = state
            #expect(DailyReadViewModel.make(from: s, isOffline: false).phase == view)
        }
    }

    /// 文章的三处派生：有没有音频、用了几块语料、大约读多久。
    ///
    /// `hasAudio` 不能只看 `audioURL != nil` —— 服务端把空的 URL 当「没有音频」发过来时
    /// 它是个**空串**，而空串会让播放按钮出现、点了什么都不会发生。
    @Test func 文章的三处派生都从内容算出来() {
        var state = DailyReadState()
        state.phase = .ready
        state.dailyRead = article(body: "hello world", audioURL: "", usedBlockIDs: ["b1"])
        let model = DailyReadViewModel.make(from: state, isOffline: false)

        let a = model.article
        #expect(a?.id == "read-1")
        #expect(a?.hasAudio == false, "空串 URL 被当成了有音频 —— 播放按钮会出现而点不动")
        #expect(a?.sourceBlockCount == 1, "语料块计数错了")
        #expect(a?.estimatedReadingSeconds == 30, "两个词的正文不该报出小于 30 秒的读数")
    }

    /// 阅读时长：约 200 词/分钟，**下限 30 秒**。
    ///
    /// 这条规则搬过来之前**一条判据都没有**，而它会在屏幕上显示成一个具体数字
    /// （「约 N 秒」）。下限不是装饰：一句话的正文否则会报「约 2 秒」，一个明显错的数
    /// 比一个取整的数更坏。
    @Test func 阅读时长按两百词每分钟并取下限() {
        func seconds(_ body: String) -> Int {
            var state = DailyReadState()
            state.phase = .ready
            state.dailyRead = article(body: body)
            return DailyReadViewModel.make(from: state, isOffline: false).article?.estimatedReadingSeconds ?? -1
        }

        // 200 词 → 60 秒；400 词 → 120 秒。
        #expect(seconds(Array(repeating: "word", count: 200).joined(separator: " ")) == 60)
        #expect(seconds(Array(repeating: "word", count: 400).joined(separator: " ")) == 120)
        // 换行与连续空白不额外计数（分词口径是「按空白」）。
        #expect(seconds("one\n\ntwo   three") == 30)
        // 空正文也落在下限上，不会是 0 或负数。
        #expect(seconds("") == 30)
    }

    /// 跟读相位的**载荷**要带过去 —— `.failed` 里有那句话，丢了它屏幕就只剩一个「失败」。
    @Test func 跟读的失败原因必须带过去() {
        var state = DailyReadState()
        state.followReadPhase = .failed("麦克风被占用")
        let model = DailyReadViewModel.make(from: state, isOffline: false)

        #expect(model.followReadPhase == .failed("麦克风被占用"))

        state.followReadPhase = .recorded
        #expect(
            DailyReadViewModel.make(from: state, isOffline: false).followReadPhase == .recorded
        )
    }

    /// 离线标记是**外部输入**，不由这一屏的状态推。
    ///
    /// 它来自 `NetworkConnectivityState`；写在签名上之后，「投影还要读根状态」这件事就不再是
    /// 一句注释里的承诺，而是类型看得见的依赖。
    @Test func 离线标记是外部输入() {
        var state = DailyReadState()
        state.phase = .ready
        state.dailyRead = article()

        let online = DailyReadViewModel.make(from: state, isOffline: false)
        let offline = DailyReadViewModel.make(from: state, isOffline: true)

        #expect(online.isOffline == false)
        #expect(offline.isOffline == true)
        // 除这一个标记外必须逐字相同 —— 否则说明它偷偷改了别的东西。
        #expect(online.article == offline.article)
        #expect(online.phase == offline.phase)
    }

    /// 兜底正文、生成日期、播放进度、跟读状态、错误 —— 逐个都要到屏幕上。
    @Test func 其余六个维度都要传到屏幕上() {
        var state = DailyReadState()
        state.phase = .fallbackPreset
        state.fallbackBody = "兜底正文"
        state.genDate = "2026-09-30"
        state.audioPhase = .playing
        state.audioPlaybackTime = 12.5
        state.audioDuration = 240
        state.hasFollowRead = true
        state.lastErrorMessage = "生成失败，先读这篇"

        let model = DailyReadViewModel.make(from: state, isOffline: false)

        #expect(model.fallbackBody == "兜底正文")
        #expect(model.genDate == "2026-09-30")
        #expect(model.audioPhase == .playing)
        #expect(model.audioPlaybackTime == 12.5)
        #expect(model.audioDuration == 240)
        #expect(model.hasFollowRead)
        #expect(model.errorMessage == "生成失败，先读这篇")
    }

    /// 四个播放相位**逐个**对应 —— 不能只测其中一个。
    ///
    /// 第一次做变异时（把 `.paused` 映成 `.playing`）这条路上**一片绿**：那时的判据只用了
    /// `.playing`，两个 case 映对没映对都看不出来。**只测一个分支的判据会替其余分支签字。**
    @Test func 四个播放相位逐个对应() {
        let expected: [(DailyReadAudioPhase, DailyReadAudioViewPhase)] = [
            (.idle, .idle),
            (.loading, .loading),
            (.playing, .playing),
            (.paused, .paused),
        ]

        for (state, view) in expected {
            var s = DailyReadState()
            s.audioPhase = state
            #expect(
                DailyReadViewModel.make(from: s, isOffline: false).audioPhase == view,
                "\(state) 没有映成 \(view)"
            )
        }
    }

    /// **评分永远不上屏**（V1.1 硬约束），即便服务端给了分。
    ///
    /// `DailyRead.readScore` 是从响应里解出来的，而投影**一个字段都不许把它带出去** ——
    /// 这条约束此前只写在 Core 的一个计算属性上，没有任何东西守在投影这一侧。
    @Test func 服务端给的分也不许上屏() {
        var state = DailyReadState()
        state.phase = .ready
        var withScore = article()
        withScore.readScore = 87.5
        state.dailyRead = withScore

        let model = DailyReadViewModel.make(from: state, isOffline: false)

        #expect(model.displayScore == nil)
        #expect(model.article?.id == "read-1", "带分的文章仍然要正常投影")
    }
}
