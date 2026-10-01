import Foundation
import Testing

/// 「每个动作都到得了屏幕，或者被写明了为什么到不了」的仓级守卫。
///
/// ## 要防的是什么
///
/// 模块轴那次清点的结论是：13 条 ❌ 里有 6 条是**「后端完整、客户端零」**，而它的成因不是
/// 「忘了写代码」，是**「数据层做完了、屏幕上没有入口」**。那类缺陷今天没有任何东西在守：
/// 一个 action 只在 reducer 里被 `switch` 过、没有任何视图派发它，测试全绿、编译通过，
/// 而学员在那台设备上**看不见这个功能**。
///
/// 所以把「有没有入口」变成机器可判的：**`AppAction` 底下每个 case，要么在屏幕层被派发，
/// 要么在这张表里、并写明它属于下面哪一类。**
///
/// ## 「屏幕层」是哪几个目录 —— 这是量出来的，不是猜的
///
/// `App/FluentWorkHost/` **＋** `Shared/FluentWorkUI/` **＋** `AppRootTabView.swift`。
///
/// 头两个显然。第三个是量出来的：底部 tab 栏那个视图住在
/// `Shared/FluentWorkCore/Navigation/AppRootTabView.swift`，而它派 `.navigation(.selectTab(...))`
/// —— 只扫 `App/` 会把 `selectTab` 误判成「没有入口」。**视图在哪个模块里是历史，不是定义。**
///
/// ## 只查一层，这也是刻意的
///
/// `AppAction` 的载荷里还有嵌套枚举（`speakingRoom.session(SpeechSessionEvent)`、
/// `navigation.selectTab(AppTab)`），它们不进这张表：
///
/// - `AppTab` 是**值**，不是动作；
/// - `SpeechSessionEvent` 是**传输泵喂给状态机的输入**（socket 收到什么就变成什么），
///   「屏幕能不能派它」对它不是对的问题 —— 27 个 case 里只有 4 个由屏幕派。
///
/// 需要被盯的那个嵌套事件是 `.session(.sessionStartTap)` —— 它由守卫 B（驱动与视图同一张表）点名。
///
/// ## 名单是双向的
///
/// 一条「永远为真」的豁免没有任何外部信号提示它已失效。所以条目指向的 case 若**改名/删掉了**、
/// 或者**现在有屏幕派它了**，守卫都要红 —— 红的意思是「把这条删掉」。
/// 这张表因此会随着 ④ 逐屏而**变短**。
///
/// ## 它已经短过一次，而且第 ③ 组已经消失
///
/// 这张表起初是**三组**：① 由中间件派（正常）、② 屏幕还没落地（债）、
/// ③ **生产代码里没有任何派发者**（死 action，14 条）。
/// 第 ③ 组不是豁免，是债单，而它的说法由一条判据当场检索验证。**那笔债已还清**（14 条全删）——
/// 所以那一组与那条判据一起消失了。这正是「一份永远为真的债单会一直长在那里假装还有债」
/// 想避免的结局：债清了，债单也走。
///
/// 顺带记下那次清理量出来的东西：那 14 条里**两整族**（`workspace.*` / `badgeFeedback.*`）
/// 的所有权本来就不在 action 上 —— `WorkspaceState` 的五个字段全是派生值，
/// `BadgeFeedbackState.ingest` 是被 `appCrossCuttingReducer` 直接调的方法。
/// 它们的 action 只是同一件事的第二条路，而**一条都没被派过**。
@Suite("屏幕入口的守卫")
struct ScreenEntryGuardTests {

    /// 一组同类条目：一条理由 + 它盖住的那些 `tag.case`。
    ///
    /// 分组而不是逐条写理由，是因为理由的性质只有两种，而条目有八十多条 ——
    /// 逐条复制同一句话会让「它们其实是同一件事」这个信息消失。
    struct Group {
        let reason: String
        let cases: [String]
    }

    static let groups: [Group] = [
        // ── ① 由中间件（或传输泵 / 机器）派发，屏幕**不该**派它 ────────────────
        //
        // 这一组是**正常**的：状态推进的中间步骤、服务端回来的东西、机器自己的事件，
        // 都从 `FluentWorkCore` 里派。屏幕派它们等于绕过流程。
        Group(
            reason: "由中间件 / 传输泵 / 机器派发 —— 状态推进的中间步骤，屏幕派它等于绕过流程",
            cases: [
                "lifecycle.bootstrapStarted", "lifecycle.bootstrapSucceeded", "lifecycle.bootstrapFailed",
                "featureFlags.applyRemoteSnapshot",
                "auth.signedInAsGuest", "auth.mergedIntoRegistered",
                "speakingRoom.userTurnStarted", "speakingRoom.aiTurnTextDelta",
                "speakingRoom.aiTurnFinalized", "speakingRoom.sessionIDCaptured",
                "speakingRoom.serverASRReceived", "speakingRoom.rescueHintArmed",
                "speakingRoom.rescueHintBecameDue",
                "review.applyPoll", "review.loadFailed", "review.acceptRefineCardStarted",
                "review.acceptRefineCardSucceeded", "review.acceptRefineCardFailed",
                "corpus.hydrateFromCache", "corpus.hydrateOutbox", "corpus.hydrateSyncMetadata",
                "corpus.initialRefreshTriggered", "corpus.remoteLoadStarted",
                "corpus.remoteLoadSucceeded", "corpus.remoteLoadFailed",
                "corpus.enqueueOutboxItem", "corpus.outboxReplayStarted",
                "corpus.outboxReplayCompleted", "corpus.outboxReplayFailed",
                "corpus.mergeRebuildStarted", "corpus.mergeRebuildPrepared",
                "corpus.mergeRebuildFinished",
                "dailyRead.hydrateFromCache", "dailyRead.applyResponse", "dailyRead.loadFailed",
                "dailyRead.audioPlaybackStarted", "dailyRead.audioPaused", "dailyRead.audioFinished",
                "dailyRead.audioFailed", "dailyRead.audioDurationLoaded",
                "dailyRead.playbackTimeUpdated", "dailyRead.followReadSucceeded",
                "dailyRead.followReadFailed",
                "sessionHistory.hydrateFromCache", "sessionHistory.loadSucceeded",
                "sessionHistory.loadFailed", "sessionHistory.detailSucceeded",
                "sessionHistory.detailFailed",
                "drill.readinessElapsed", "drill.answerDeadlineReached", "drill.roundLoaded",
                "drill.roundLoadFailed", "drill.verdictReceived", "drill.attemptFailed",
                "drill.appealResolved", "drill.applyRound",
                "topic.cardsLoaded", "topic.cardsFailed", "topic.statsLoaded",
                "topic.checkinSucceeded", "topic.checkinFailed", "topic.dismissSucceeded",
                "topic.dismissFailed",
                // 创建练习（屏 11）：素材建好 / 建失败，由 `createPracticeMiddleware` 派。
                // 屏幕派它们等于自己造一个「素材已经建好了」的结果。
                "createPractice.created", "createPractice.submissionFailed",
                // 命中徽章：由**传输层**派（socket 的 `feedback.badge` 帧 →
                // `appCrossCuttingReducer` → `BadgeFeedbackReducer` → 屏幕上的徽章层）。
                // 屏幕上曾经有一个 DEBUG 注入页脚，它是这个 action 唯一的**屏幕**入口 ——
                // 那条页脚连着「注入徽章」一起删掉了（它不在稿子里），所以这里要写明理由，
                // 而不是让守卫以为「数据层做完了、屏幕上没有入口」。
                "speakingRoom.badgeHit",
                // 删数据（屏 12 的「删除我的全部素材」）：**回执与失败由 `accountDataMiddleware` 派**。
                // 屏幕派它们等于自己造一个「已经删掉了」的结果 —— 而这条链路是不可逆的，
                // 屏幕上唯一该做的是把「确认」派出去、然后等真实回执。
                "accountData.deleteSucceeded", "accountData.deleteFailed",
                // 账号登录的结果由 `accountAuthMiddleware` 派（屏幕派等于自己造一个
                // 「已经登录成功了」的结果）。`.submitTapped` 仍是屏幕派的，见下面第二组。
                "accountAuth.succeeded", "accountAuth.failed",
                "network.connectivityChanged",
            ]
        ),

        // ── ② 屏幕还没落地（④ 逐屏时这一组会一起消失） ────────────────────────
        Group(
            reason: "屏幕还没落地（④ 逐屏）—— 数据层与中间件都已接线",
            cases: [
                // 闪测屏（E1/E2/E4 的屏幕）—— **它卡在一条不存在的采集链路上**：
                // 这 7 条里有 5 条是屏幕能派的，而 `.answerCaptured` 要的是 ASR 文本，
                // 客户端今天没有任何东西产出它（`ClientASRTranscriber` 是一份没接线的文档）。
                // 见 `docs/design/ui-verification-strategy.md` 的 ④ 一节。
                "drill.startTapped", "drill.answerCaptured", "drill.skipTapped",
                "drill.retryTapped", "drill.advanceTapped", "drill.appealTapped",
                "drill.exitTapped",

                // 账号表单（屏 15）—— **中间件已经落地，缺的是屏幕**：
                // 这 4 条都由登录页派，而登录页还没写。屏 15 一落地它们就离开这一组。
                "accountAuth.modeChanged", "accountAuth.emailChanged",
                "accountAuth.passwordChanged", "accountAuth.submitTapped",
            ]
        ),

        // ── ③ 生产代码里**没有任何**派发者 —— 死 action，待清理 ────────────────
        //
    ]

    /// 扁平成 `tag.case` → 理由，供双向校验用。
    static var table: [String: String] {
        var out: [String: String] = [:]
        for group in groups {
            for entry in group.cases { out[entry] = group.reason }
        }
        return out
    }

    /// **每个 `AppAction` 底下的 case，要么在屏幕层被派发，要么在表里。**
    @Test func everyRootActionReachesAScreenOrIsExplained() throws {
        let unreachable = try Self.casesWithoutScreenEntry()
        let unexplained = unreachable.filter { Self.table[$0] == nil }

        #expect(
            unexplained.isEmpty,
            """
            这些动作**在屏幕层没有任何派发点**，也没写明为什么：
            \(unexplained.joined(separator: "\n"))
            两条路：把它接到某个视图的回调上，或者加进 `groups` 并写下理由。
            这条守卫挡的正是模块轴那 6 条的成因 —— **数据层做完了、屏幕上没有入口**。
            """
        )
    }

    /// 名单双向：条目过期（case 改名了、或现在有屏幕派它了）也要红。
    @Test func theExemptListHasNoStaleEntries() throws {
        let stillUnreachable = Set(try Self.casesWithoutScreenEntry())
        let stale = Self.table.keys.filter { !stillUnreachable.contains($0) }

        #expect(
            stale.isEmpty,
            """
            这些条目已经失效（case 改名/删掉了，或现在已经有屏幕派它了），请从表里删掉：
            \(stale.sorted().joined(separator: "\n"))
            一份永远为真的债单会一直长在那里假装还有债。
            """
        )
    }

    /// 守卫在看真代码，而不是在看空气。
    ///
    /// 目录改名、`AppAction` 换写法、正则写坏，都会让「没有屏幕入口」的集合**变成全部**，
    /// 而那时上面几条判据会一起红、却指不出真正的原因。这条先把「检索还有效」钉住：
    /// 先量总数，再用几个**已知有屏幕入口**的动作点名验一遍。
    @Test func theScanSeesBothSides() throws {
        let enums = try Self.rootActionEnums()
        // 12 = 删掉 `workspace` / `badgeFeedback` 两族之后的根动作枚举数
        // （lifecycle / featureFlags / auth / speakingRoom / review / corpus / dailyRead /
        // sessionHistory / drill / topic / network / navigation）。
        // 这是个**地板**，不是等式：它要抓的是「枚举解析坏了」（那会让下面几条静默变绿）。
        #expect(enums.count >= 12, "只解析出 \(enums.count) 个根动作枚举 —— `AppAction` 的写法变了")

        let all = try enums.flatMap { pair in
            try Self.cases(of: pair.enumName).map { caseName in "\(pair.tag).\(caseName)" }
        }
        #expect(all.count >= 95, "只解析出 \(all.count) 个 case —— 枚举解析坏了")

        let unreachable = try Self.casesWithoutScreenEntry()
        let reachable = Set(all).subtracting(unreachable)
        #expect(
            reachable.count >= 30,
            "只有 \(reachable.count)/\(all.count) 个动作被判为「有屏幕入口」—— 检索多半坏了"
        )

        // 点名验：每一个都代表一种「入口的形状」，漏掉任何一类都说明检索偏了。
        //
        // 注意这里写的是 `speakingRoom.session` 而不是 `…sessionStartTap` —— 嵌套载荷里的 case
        // **刻意不进这张表**（见文件头的说明），能被点名的只有承载它的那个 case。
        for entry in [
            "corpus.appear",                    // `App/` 的直接派发
            "speakingRoom.session",             // 嵌套载荷的承载 case（`.speakingRoom(.session(.…))`）
            "speakingRoom.manualSpeechBegin",   // 同一个 tag 下的另一个 case
            "dailyRead.playTapped",             // 每日一读的播放按钮
            "navigation.selectTab",             // 唯一一个在 `AppRootTabView.swift`（住在 Core 的视图）里的
            "review.acceptRefineCardTapped",    // 多行 `dispatch(...)` 形状
        ] {
            #expect(
                reachable.contains(entry),
                "\(entry) 明明有屏幕入口，却被判成没有 —— 屏幕层的作用域或检索写错了"
            )
        }
    }

    // MARK: - 检索

    /// `AppAction` 里 `case tag(PayloadEnum)` 的成对清单。
    static func rootActionEnums() throws -> [(tag: String, enumName: String)] {
        let source = try productionSource(named: "Shared/FluentWorkCore/Architecture/AppState.swift")
        guard let body = enumBody(named: "AppAction", in: source) else { return [] }
        return matches(#"case\s+(\w+)\s*\(\s*(\w+)\s*\)"#, in: body).map { ($0[1], $0[2]) }
    }

    /// 某个动作枚举自己的 case 名。
    static func cases(of enumName: String) throws -> [String] {
        for source in try RepositoryScan.productionSources() {
            guard let body = enumBody(named: enumName, in: source.text) else { continue }
            return matches(#"(?m)^\s*case\s+(\w+)"#, in: body).map { $0[1] }
        }
        return []
    }

    /// 屏幕层：`App/` ＋ `Shared/FluentWorkUI/` ＋ `AppRootTabView.swift`。
    static func screenLayerText() throws -> String {
        let fromDirectories = try RepositoryScan.productionSources()
            .filter {
                $0.relativePath.hasPrefix("App/")
                    || $0.relativePath.hasPrefix("Shared/FluentWorkUI/")
            }
            .map(\.text)
        let extras = try [
            "Shared/FluentWorkCore/Navigation/AppRootTabView.swift"
        ].map { try productionSource(named: $0) }

        return (fromDirectories + extras)
            .map { RepositoryScan.codeLines(of: $0).map(\.text).joined(separator: "\n") }
            .joined(separator: "\n")
    }

    /// `tag.case` 形态的、在屏幕层**一个派发点都没有**的那些 case。
    static func casesWithoutScreenEntry() throws -> [String] {
        let screen = try screenLayerText()

        var unreachable: [String] = []
        for (tag, enumName) in try rootActionEnums() {
            for caseName in try cases(of: enumName) {
                // `\.tag\(\s*\.case` —— 容忍换行与缩进：视图里多行的 `dispatch(...)` 就是这种形状。
                let pattern = #"\.\#(tag)\(\s*\.\#(caseName)\b"#
                if !matches(pattern, in: screen).isEmpty { continue }
                unreachable.append("\(tag).\(caseName)")
            }
        }
        return unreachable.sorted()
    }

    // MARK: - 小工具

    private static func productionSource(named relativePath: String) throws -> String {
        let url = RepositoryScan.repositoryRoot.appending(path: relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 某个枚举声明的花括号内容。用「`public enum Name` 之后那对花括号」的近似，
    /// 对本仓的扁平枚举足够；解析不到就返回 `nil`（由 sanity 判据兜住）。
    private static func enumBody(named name: String, in text: String) -> String? {
        let pattern = #"public enum \#(name)\b[^\{]*\{"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let full = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: full),
              let range = Range(match.range, in: text)
        else {
            return nil
        }

        var depth = 0
        var index = range.upperBound
        let start = index
        while index < text.endIndex {
            let character = text[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                if depth == 0 { return String(text[start..<index]) }
                depth -= 1
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// 全部捕获组（含第 0 组）。插值进来的都是标识符，不需要额外转义。
    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let full = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: full).map { match in
            (0..<match.numberOfRanges).map { index in
                guard let range = Range(match.range(at: index), in: text) else { return "" }
                return String(text[range])
            }
        }
    }
}
