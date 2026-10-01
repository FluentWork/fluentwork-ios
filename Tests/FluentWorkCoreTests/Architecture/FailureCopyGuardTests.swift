import Foundation
import Testing

// MARK: - 面向学员的失败文案：全局判据
//
// 出处：2026-10-01 屏 05 的第一张截图里端出的是
// `The operation couldn't be completed. (FluentWorkCore.TokenError error 0.)` ——
// 那一处是**眼睛**（截图）抓到的，判据一条都没抓到（`DrillMiddleware` 的注释里留着这句话）。
// 逐屏靠人看不算纪律，所以这一票把规矩提到仓级：
//
// 1. **中间件一个字节都不许自己格式化 `Error`** —— 学员能看到的每一句失败文案都在
//    `Architecture/Middleware/` 里成形，把住这一个门，就没有第二处能漏出来；
// 2. **每个开口说话的中间件必须有一个 `*ErrorMessage` seam**，且 seam 名单要登记 ——
//    名字在那儿，「这句话是谁写的」才有唯一的落点。

/// 中间件的代码里不许出现任何「开发字符串」的来源。
///
/// 禁令不是一条而是五条：`localizedDescription` 只是最常见的那一个。同一个病还有
/// `.errorDescription`（`LocalizedError` 那层）、`String(describing:)` / `String(reflecting:)`，
/// 以及直接插值 `\(error)`。只堵第一条，换个写法就绕过去了。
@Test func middlewareNeverFormatsAnErrorItself() throws {
    let files = try swiftFiles(in: "Shared/FluentWorkCore/Architecture/Middleware")
    #expect(
        files.count >= 10,
        "只扫到 \(files.count) 个中间件 —— 这个守卫正在看空气，先修扫描再信它的绿"
    )

    var offenders: [String] = []
    for url in files {
        let code = strippingComments(try String(contentsOf: url, encoding: .utf8))
        for (offset, line) in code.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
        where bannedDevelopmentStringSources.contains(where: line.contains) {
            offenders.append("\(url.lastPathComponent):\(offset + 1)")
        }
    }

    #expect(
        offenders.isEmpty,
        """
        中间件把开发字符串端给学员了：\(offenders.joined(separator: ", "))
        这里是那句话成形的唯一地方，所以规矩落在这里：**先翻译，再派**。
        改成该中间件自己的 `*ErrorMessage` seam（下一张断言里有登记表）。
        """
    )
}

/// `*ErrorMessage` seam 的登记表 —— **既查漏，也查多**。
///
/// 查漏：登记过的 seam 不许消失（消失了说明那句文案没人负责了）。
/// 查多：源码里冒出来的新 seam 必须登记 —— 登记表是「一共有几种失败文案」的答案，
/// 它一旦不全，下一个人就会再造一份。
@Test func everyFailureCopySeamIsRegistered() throws {
    let files = try swiftFiles(in: "Shared/FluentWorkCore/Architecture/Middleware")
    #expect(files.count >= 10, "只扫到 \(files.count) 个中间件 —— 这个守卫正在看空气")

    var found: Set<String> = []
    for url in files {
        let code = strippingComments(try String(contentsOf: url, encoding: .utf8))
        for match in code.matches(of: /func\s+([A-Za-z]+ErrorMessage)\s*\(/) {
            found.insert(String(match.1))
        }
    }

    let registered: Set<String> = [
        "drillErrorMessage",
        "createPracticeErrorMessage",
        "accountDataErrorMessage",
        "accountAuthErrorMessage",
        // `AppBootstrapMiddleware.swift` 一个文件里住着四个中间件，所以它有三个 seam。
        "appBootstrapErrorMessage",
        "reviewErrorMessage",
        "corpusErrorMessage",
        "sessionHistoryErrorMessage",
        "dailyReadErrorMessage",
        "topicErrorMessage",
        "speechSessionErrorMessage",
    ]

    #expect(
        registered.subtracting(found).isEmpty,
        """
        这些 seam 在登记表里，源码里却没有了：\(registered.subtracting(found).sorted())
        学员的失败文案不能没有落点 —— 要么把它加回来，要么把登记表里这一行删掉并说明谁接手了。
        """
    )
    #expect(
        found.subtracting(registered).isEmpty,
        """
        冒出了没登记的失败文案 seam：\(found.subtracting(registered).sorted())
        把它们加进 `registered` —— 那张表是「一共有几种失败文案」的答案。
        """
    )
}

// MARK: - 扫描工具
//
// 这两个都不是洁癖，各自对应一次真实的误判：

/// 剥掉注释，**但要认字符串**。
///
/// 1. 三个 seam 的文档注释里就写着「不许端 `localizedDescription`」这句话本身 ——
///    不剥注释，守卫会被自己的说明文字绊倒（`DrillMiddleware` / `AccountDataMiddleware` /
///    `AccountAuthMiddleware` 各有一条）；
/// 2. 剥的时候必须知道自己在不在字符串里：`URL(string: "http://127.0.0.1:8080")` 里的 `//`
///    不是注释开头。按行找 `//` 会**静默吃掉这一行的后半段代码** —— 那是假绿，
///    比漏报更糟。
///
/// 已知边界：`"""` 多行字符串按「空串 + 新串」处理，中间的内容会被当成代码。
/// 中间件里没有多行字符串，出现时这条会以**误报**（而不是漏报）的形式暴露出来。
func strippingComments(_ source: String) -> String {
    var out = ""
    var index = source.startIndex
    var inLineComment = false
    var inBlockComment = false
    var inString = false
    var escaped = false

    while index < source.endIndex {
        let char = source[index]
        let next = source.index(after: index)

        if inLineComment {
            if char == "\n" {
                inLineComment = false
                out.append(char)
            }
            index = next
            continue
        }

        if inBlockComment {
            if char == "*", next < source.endIndex, source[next] == "/" {
                inBlockComment = false
                index = source.index(after: next)
                continue
            }
            if char == "\n" { out.append(char) }
            index = next
            continue
        }

        if inString {
            out.append(char)
            if escaped {
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else if char == "\"" {
                inString = false
            }
            index = next
            continue
        }

        if char == "\"" {
            inString = true
            out.append(char)
            index = next
            continue
        }
        if char == "/", next < source.endIndex, source[next] == "/" {
            inLineComment = true
            index = source.index(after: next)
            continue
        }
        if char == "/", next < source.endIndex, source[next] == "*" {
            inBlockComment = true
            index = source.index(after: next)
            continue
        }

        out.append(char)
        index = next
    }

    return out
}

/// 「开发字符串」的全部来源。加第七条禁令时，**先说清它和已有六条哪里不同**。
let bannedDevelopmentStringSources = [
    "localizedDescription",
    ".errorDescription",
    "String(describing:",
    "String(reflecting:",
    "\\(error)",
]

func swiftFiles(in relativeDirectory: String) throws -> [URL] {
    let base = repositoryRoot.appending(path: relativeDirectory)
    guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
        return []
    }
    return
        walker
        .compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.path < $1.path }
}

private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
