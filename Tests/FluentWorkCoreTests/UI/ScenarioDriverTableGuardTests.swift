import Foundation
import Testing

/// 「真机场景驱动与视图出自同一张表」的仓级守卫。
///
/// ## 要防的是什么
///
/// `Debug/DeviceScenarioDriver.swift` 是今天「自动点屏幕」的替代：仅 DEBUG、由 `FW_SCENARIO`
/// 开启、**照视图派同样的 action**。它的价值全部建立在「照抄」上 —— 一旦它自己发明一步，
/// 它验的就不是真机上的那条路，而它的 FAIL 会去指责被测对象。
///
/// 这件事真的发生过：驱动第 ③ 步曾经派 `.manualSpeechBegin`（那是「开始说话」按钮），
/// 而**起会话的是 `.sessionStartTap`**（`HostRootView.restartOrStartSpeakingSession()`）。
/// 于是驱动永远停在 `.idle`：会话从头到尾没被创建，而它把这件事报成
/// **「30 秒内没有进入采集」** —— 判据在指责被测对象，错的是派 action 的人。23:28 那次
/// `room+daily` 的 FAIL 就是这个。
///
/// ## 这一层守什么
///
/// 1. 表里每一步的派发语句，**驱动里有、屏幕层也有** —— 这是「同一张表」的字面意思；
/// 2. 驱动**不许自创流程**：它派出的每个动作，屏幕层都必须也能派（否则它测的是一条
///    真机上走不到的路）；
/// 3. 表是双向的：某一步从驱动里消失（或从屏幕上消失）也要红。
///
/// 「屏幕层」的作用域与 `ScreenEntryGuardTests` 一致（`App/` ＋ `Shared/FluentWorkUI/`
/// ＋ `AppRootTabView.swift`），那边解释了为什么是这三个。
///
/// **注意这一层是读源码文本，不是引用类型**：驱动整个在 `#if DEBUG` 里，而这里要查的是
/// 「它派了什么」，那是文本事实。
@Suite("驱动与视图同一张表的守卫")
struct ScenarioDriverTableGuardTests {

    /// 驱动的路径（相对仓根）。
    static let driverPath = "Shared/FluentWorkCore/Debug/DeviceScenarioDriver.swift"

    /// 真机场景里每一步应当派什么，以及**屏幕上这一句的出处**。
    ///
    /// `viewSite` 不是装饰：它是这一行值得被信任的理由 —— 没有它，这张表就只是「驱动做了什么」，
    /// 而不是「驱动抄了屏幕上的哪一下」。
    struct Step {
        let scenario: String
        let name: String
        /// 派发语句的**前缀**（到内部闭括号为止），两侧都要能逐字找到它。
        let dispatch: String
        /// 屏幕上这一句的出处。
        let viewSite: String
    }

    static let steps: [Step] = [
        Step(
            scenario: "room",
            name: "① 启动",
            dispatch: ".lifecycle(.appLaunched)",
            viewSite: "HostRootView 的 `.task`（`didLaunch` 那次）"
        ),
        Step(
            scenario: "room",
            name: "② 进房间",
            dispatch: ".speakingRoom(.enterRoom(",
            viewSite: "房间的 `.onAppear`（把路由参数 `sessionID` 变成 `continueFrom`）"
        ),
        Step(
            scenario: "room",
            name: "③ 起会话",
            dispatch: ".speakingRoom(.session(.sessionStartTap",
            viewSite: "`restartOrStartSpeakingSession()` —— 「开始 / 重新开始」那个按钮"
        ),
        Step(
            scenario: "room",
            name: "开始说话",
            dispatch: ".speakingRoom(.manualSpeechBegin)",
            viewSite: "`onStartTapped` 里 `.beginTurn` 那一支（「开始说话」按钮）"
        ),
        Step(
            scenario: "room",
            name: "⑤ 收尾",
            dispatch: ".speakingRoom(.manualSpeechEnd)",
            viewSite: "`onStopTapped` 里 `.endTurn` 那一支"
        ),
        Step(
            scenario: "room+daily",
            name: "④ 播每日一读",
            dispatch: ".dailyRead(.loadTriggered)",
            viewSite: "每日一读页的 `.onAppear`"
        ),
    ]

    /// **每一步都要在两侧找得到** —— 这就是「同一张表」的字面检查。
    ///
    /// 双向往返：某一步从驱动里消失了（有人删了它）红；从屏幕层消失了（按钮改了、改名了）也红。
    /// 后一半更要紧：屏幕改了而驱动没改，就是 23:28 那次的形状。
    @Test func everyStepExistsOnBothSides() throws {
        let driver = try Self.text(at: Self.driverPath)
        let screen = try ScreenEntryGuardTests.screenLayerText()

        var missingInDriver: [String] = []
        var missingOnScreen: [String] = []

        for step in Self.steps {
            if !driver.contains(step.dispatch) {
                missingInDriver.append("\(step.scenario)/\(step.name)  \(step.dispatch)")
            }
            if !screen.contains(step.dispatch) {
                missingOnScreen.append("\(step.scenario)/\(step.name)  \(step.dispatch)")
            }
        }

        #expect(
            missingInDriver.isEmpty,
            """
            这些步骤不在驱动里了（表已经过期，或者有人删了驱动的一步）：
            \(missingInDriver.joined(separator: "\n"))
            表是双向的：驱动少了一步要红，多了没写进表的一步也要红。
            """
        )
        #expect(
            missingOnScreen.isEmpty,
            """
            这些步骤在驱动里有，但**屏幕层里找不到同一句**：
            \(missingOnScreen.joined(separator: "\n"))
            这意味着驱动在派一个屏幕上到不了的 action —— 它验的就不是真机那条路了。
            23:28 那次就是这么来的（驱动派了「开始说话」，而起会话的是另一个按钮）。
            """
        )
    }

    /// **驱动不许自创流程。**
    ///
    /// 上面那条只管表里写下的几步；这一条管**驱动派出的每一个动作**：屏幕层都得能派。
    /// 新加一步忘了写进表，这条会兜住它。
    @Test func theDriverInventsNoActionTheScreenCannotDispatch() throws {
        let driver = try Self.text(at: Self.driverPath)
        let screen = try ScreenEntryGuardTests.screenLayerText()

        let dispatched = try Self.dispatchPatterns(in: driver)
        #expect(dispatched.count >= 5, "只从驱动里读出 \(dispatched.count) 个派发 —— 检索写坏了")

        let invented = dispatched.filter { pattern in
            !Self.matches(pattern, in: screen)
        }

        #expect(
            invented.isEmpty,
            """
            驱动派了这些**屏幕层派不出**的动作：
            \(invented.sorted().joined(separator: "\n"))
            驱动唯一的纪律是「照抄视图，不自创流程」—— 自查一下这一步真机上该按哪个按钮，
            再把两边改成同一句。
            """
        )
    }

    /// 守卫在读真代码，而不是在读空气。
    ///
    /// 驱动改名、`FW_SCENARIO` 那段被挪走、屏幕层作用域写坏，都会让上面两条**静默变绿**
    /// （读不到派发 ⇒ 没有「自创」的、表里那几步也找得到就过了）。这条先把「两侧都读到了东西」钉住。
    @Test func theGuardSeesBothSidesOfTheTable() throws {
        let driver = try Self.text(at: Self.driverPath)
        #expect(
            driver.contains("FW_SCENARIO"),
            "驱动文件里没有 `FW_SCENARIO` —— 读到的是别的文件，或者它被改名了"
        )

        let screen = try ScreenEntryGuardTests.screenLayerText()
        #expect(screen.count > 10_000, "屏幕层只读到 \(screen.count) 个字符 —— 作用域写坏了")

        // 这里刻意用与守卫 A 相同的入口，免得两处作用域悄悄分叉。
        // 地板从 3 降到 2：守卫 A 的第三组（死 action 债单）在 2026-10-01 随 14 条死 action
        // 一起删除 —— 债还清了，债单也该走。
        #expect(
            ScreenEntryGuardTests.groups.count >= 2,
            "守卫 A 的豁免表结构变了 —— 两个守卫共用的那部分要一起改"
        )
    }

    // MARK: - 检索

    /// 文本里全部 `.tag(.case` 形态的派发（去重、排序），只保留**已知的根动作 tag**。
    ///
    /// 两处细节都是踩出来的：
    ///
    /// - 正则带**前瞻**（`(?=\.(\w+))`）。不带前瞻时扫描是**不重叠**的：`store.dispatch(.speakingRoom(`
    ///   会先匹配掉 `.dispatch(.speakingRoom`，于是**真正的那一步被吃掉** —— 第一次跑就只读出 4 个
    ///   派发（而驱动里有 6 个），差点让「驱动不许自创流程」这条判据在半盲的状态下通过。
    /// - tag 必须是 `AppAction` 里真实存在的那些，否则 `.dispatch(` / `.session(` 这类噪音会被
    ///   当成一步。名单从 `AppAction` 解析而来，不手抄。
    static func dispatchPatterns(in text: String) throws -> [String] {
        let knownTags = Set(try ScreenEntryGuardTests.rootActionEnums().map(\.tag))
        let regex = try? NSRegularExpression(pattern: #"\.(\w+)\(\s*(?=\.(\w+)\b)"#)
        let full = NSRange(text.startIndex..., in: text)

        let found = (regex?.matches(in: text, range: full) ?? []).compactMap { match -> String? in
            guard let tag = Range(match.range(at: 1), in: text),
                  let caseName = Range(match.range(at: 2), in: text)
            else {
                return nil
            }
            let name = String(text[tag])
            guard knownTags.contains(name) else { return nil }
            return #"\.\#(name)\(\s*\.\#(text[caseName])\b"#
        }
        return Array(Set(found)).sorted()
    }

    /// 只剔整行注释（与仓里其它守卫同一约定）。
    static func text(at relativePath: String) throws -> String {
        let url = RepositoryScan.repositoryRoot.appending(path: relativePath)
        let raw = try String(contentsOf: url, encoding: .utf8)
        return RepositoryScan.codeLines(of: raw).map(\.text).joined(separator: "\n")
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
