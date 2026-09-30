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
/// `workspace.activate(WorkspaceSurface)`、`navigation.selectTab(AppTab)`），它们不进这张表：
///
/// - `WorkspaceSurface` / `AppTab` 是**值**，不是动作；
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
@Suite("屏幕入口的守卫")
struct ScreenEntryGuardTests {

    /// 一组同类条目：一条理由 + 它盖住的那些 `tag.case`。
    ///
    /// 分组而不是逐条写理由，是因为理由的性质只有三种，而条目有九十多条 ——
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
                "network.connectivityChanged",
            ]
        ),

        // ── ② 屏幕还没落地（④ 逐屏时这一组会一起消失） ────────────────────────
        Group(
            reason: "屏幕还没落地（④ 逐屏）—— 数据层与中间件都已接线",
            cases: [
                // D2 的丢弃 / 编辑：reducer 与中间件都在，只差按钮。
                "review.discardRefineCardTapped", "review.restoreRefineCardTapped",
                "review.refineCardEditChanged", "review.refineCardEditReverted",
                // 闪测屏（E1/E2/E4 的屏幕）—— **它卡在一条不存在的采集链路上**：
                // 这 7 条里有 5 条是屏幕能派的，而 `.answerCaptured` 要的是 ASR 文本，
                // 客户端今天没有任何东西产出它（`ClientASRTranscriber` 是一份没接线的文档）。
                // 见 `docs/design/ui-verification-strategy.md` 的 ④ 一节。
                "drill.startTapped", "drill.answerCaptured", "drill.skipTapped",
                "drill.retryTapped", "drill.advanceTapped", "drill.appealTapped",
                "drill.exitTapped",
            ]
        ),

        // ── ③ 生产代码里**没有任何**派发者 —— 死 action，待清理 ────────────────
        //
        // 这一组不是豁免，是**债单**。它们的「没有派发者」由下面
        // `theDeadActionsAreStillUndispatchedEverywhere` 一条判据**当场验证**，
        // 所以这一行注释不是印象：检索面是全部生产代码（`Shared` + `App`）。
        Group(
            reason: "生产代码里没有任何派发者 —— 死 action（判据当场验证），待清理",
            cases: [
                // `WorkspaceState` / `BadgeFeedbackState` 各有两个写入者：它们自己的 reducer
                // （经 action）与 `appCrossCuttingReducer`（直接改 state）。今天生效的是后者，
                // 下面这些 action 因此从未被派发 —— 它们长着一副「有东西在派我」的样子。
                // 证据：`AppReducer.swift:139`（`isBootstrapComplete`）、`:140`（`activeSurface`）、
                // `:171`（`highlightedBadge` / `badgeFeedCount`）、`:184`（直接调
                // `state.badgeFeedback.ingest(...)`）、`:211`（`availableModules`）。
                "workspace.setBootstrapComplete", "workspace.activate", "workspace.recordBadgeHit",
                "workspace.setAvailableModules", "badgeFeedback.ingest",
                "badgeFeedback.tick", "badgeFeedback.clear",
                "speakingRoom.bootstrapReady", "speakingRoom.userSpeechCaptured",
                "speakingRoom.aiTurnEndReceived",
                "review.clear",
                "corpus.removeOutboxItem", "corpus.outboxReplayFinished", "corpus.reset",
            ]
        ),
    ]

    /// 扁平成 `tag.case` → 理由，供双向校验用。
    static var table: [String: String] {
        var out: [String: String] = [:]
        for group in groups {
            for entry in group.cases { out[entry] = group.reason }
        }
        return out
    }

    /// 「死 action」那一组 —— 单独取出来，好让判据能验证它。
    static var deadActions: [String] {
        groups.first { $0.reason.contains("没有任何派发者") }?.cases ?? []
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

    /// **「死 action」那一组的说法要能被当场验证。**
    ///
    /// 上一条只保证「它们没有**屏幕**入口」；这一条管的是更强的那个断言 ——
    /// **全部生产代码里都没有派发者**。少了它，那一组会退化成一句无人核对的话，
    /// 而「死 action」这个标签恰恰是给人做清理决定用的。
    ///
    /// 有人把它们接上（无论接在屏幕还是中间件上）时，这条会红 —— 那时把它从 ③ 挪走。
    @Test func theDeadActionsAreStillUndispatchedEverywhere() throws {
        let all = try RepositoryScan.productionSources()
            .map { RepositoryScan.codeLines(of: $0.text).map(\.text).joined(separator: "\n") }
            .joined(separator: "\n")

        let revived = Self.deadActions.filter { entry in
            let parts = entry.split(separator: ".")
            guard parts.count == 2 else { return false }
            let pattern = #"\.\#(parts[0])\(\s*\.\#(parts[1])\b"#
            return !Self.matches(pattern, in: all).isEmpty
        }

        #expect(
            revived.isEmpty,
            """
            这些动作已经被接上了派发点，但它们还挂在「死 action」那一组里：
            \(revived.sorted().joined(separator: "\n"))
            把它们挪到 ① 或 ②，或者从表里删掉，或者把死代码删掉。
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
        #expect(enums.count >= 14, "只解析出 \(enums.count) 个根动作枚举 —— `AppAction` 的写法变了")

        let all = try enums.flatMap { pair in
            try Self.cases(of: pair.enumName).map { caseName in "\(pair.tag).\(caseName)" }
        }
        #expect(all.count >= 100, "只解析出 \(all.count) 个 case —— 枚举解析坏了")

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
