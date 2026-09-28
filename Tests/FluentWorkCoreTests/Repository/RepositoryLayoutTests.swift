import Foundation
import Testing

/// 仓库骨架的守卫（F8）。
///
/// ## 要防的是什么
///
/// `.github/workflows/ios-ci.yml` 里的 `repo-structure-check` 断言过
/// `Modules/`、`Services/`、`Resources/` —— **这三个目录本仓从来没有过**
/// （真实骨架是 `App / Shared / Tests / Scripts`）。于是那条检查在**每次推送时都红**。
///
/// 这类断言比"没有断言"更坏：**一个永远红的检查不再携带信息**，
/// 人们会学会忽略它，包括它真正该报的那一次。而它自己不会被任何东西发现 ——
/// 除非有一条判据反过来查它。
///
/// ## 判据：CI 说的骨架必须是真的骨架
///
/// `.github/workflows/*.yml` 里每一条 `test -d/-f/-x <路径>` 断言
/// **必须指到真实存在的东西**。带反空洞下限：解析失配（正则不再匹配、
/// 目录改名）时必须红，而不是"没找到任何东西 ⇒ 视为通过"。
///
/// ## 一条**没做**的判据，以及为什么
///
/// 原本还想在这里断言「`Package.swift` 里每个 `path:` 都落在真实目录上」。
/// 变异验证时发现它是**死判据**：把 `path: "Shared/FluentWorkPluginSupport"`
/// 改成不存在的名字，SwiftPM 在**加载清单**阶段就报
/// `error: invalid custom path '…' for target '…'`，测试根本不会开始跑。
/// 也就是说这条不变量已经由工具链更响亮地保证了，再写一遍只会多一条
/// 永远不可能独立开火、却看起来在守东西的判据 —— 本项目对这类
/// 「看起来在守、实际是死的」判据是当负债处理的，所以删掉。
///
/// （顺带查出一处真空白：`project.yml` 的源路径与 product 名**没有任何东西校验**
/// —— CI 不跑 `xcodegen`，而门禁腿 2 构建的是**已提交的** `.xcodeproj`，
/// 所以 project.yml ⇄ Package.swift 不一致时谁都不会说话。另立 F8-b，不并进本票。）
@Suite struct RepositoryLayoutTests {

    /// CI 工作流里断言的每个路径都必须真实存在。
    ///
    /// 这条判据的价值不在于"跑起来会红"，而在于**它现在就是绿的、且以后不许变红**：
    /// 谁再把 `test -d Modules` 写回去（或者删掉 `Scripts/gate.sh` 却留着断言），
    /// `swift test` 立刻报出是哪一行、哪个路径。
    @Test func everyPathAssertedInCIWorkflowsExists() throws {
        let root = Self.repositoryRoot
        let workflowsDirectory = root.appending(path: ".github/workflows")
        let workflows = try FileManager.default
            .contentsOfDirectory(atPath: workflowsDirectory.path)
            .filter { $0.hasSuffix(".yml") || $0.hasSuffix(".yaml") }
            .sorted()

        #expect(!workflows.isEmpty, ".github/workflows 里没有找到任何工作流文件")

        var assertions: [(origin: String, flag: String, path: String)] = []
        for workflow in workflows {
            let text = try String(
                contentsOf: workflowsDirectory.appending(path: workflow),
                encoding: .utf8
            )
            for match in Self.captureGroups(
                of: #"test\s+-([dfx])\s+"?([^"\s]+)"?"#,
                in: text
            ) {
                assertions.append((origin: workflow, flag: match[0], path: match[1]))
            }
        }

        // 反空洞下限，同时也是**棘轮**：当前两条工作流共 9 条路径断言。
        // 少一条就红 —— 删掉一条 CI 检查应该是有意识的动作，不该顺手滑过去；
        // 真要减，就同时改这个数，而这条注释会回答"当初为什么是 9"。
        // （它同时兜住另一种失败：正则失配时数会是 0，那时绝不能算通过。）
        #expect(
            assertions.count >= 9,
            "只从工作流里解析出 \(assertions.count) 条路径断言 —— 要么删了检查、要么解析器失配（期望 >= 9）"
        )

        var missing: [String] = []
        for assertion in assertions {
            let url = root.appending(path: assertion.path)
            let exists: Bool
            switch assertion.flag {
            case "d":
                exists = FileManager.default.fileExists(atPath: url.path)
            case "f":
                var isDirectory: ObjCBool = false
                exists =
                    FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && !isDirectory.boolValue
            case "x":
                exists = FileManager.default.isExecutableFile(atPath: url.path)
            default:
                exists = false
            }
            if !exists {
                missing.append(
                    "\(assertion.origin): `test -\(assertion.flag) \(assertion.path)` —— 这个路径不存在"
                )
            }
        }

        #expect(
            missing.isEmpty,
            """
            CI 里断言了不存在的路径（那条检查会永远红，而永远红的检查不携带信息）：
            \(missing.joined(separator: "\n"))
            """
        )
    }

    // MARK: - 解析

    /// 取每条匹配的全部捕获组。
    private static func captureGroups(of pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).map { match in
            (1..<match.numberOfRanges).compactMap { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) }
            }
        }
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
