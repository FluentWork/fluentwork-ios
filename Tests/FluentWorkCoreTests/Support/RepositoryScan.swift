import Foundation

/// 仓级守卫共用的扫描工具。
///
/// 抽到 Support 而不是每个守卫各写一份 —— 同一段「遍历生产代码 + 剔除整行注释」
/// 在三个守卫里各存一份，就是 F2 刚收敛掉的那种重复（`waitUntil` 曾有 8 份）。
enum RepositoryScan {

    /// 生产代码的根（仓根）。以本文件位置反推，不依赖当前工作目录。
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// 遍历生产代码（`Shared` + `App`）下的 Swift 文件。
    ///
    /// 扫描根是**目录结构**，所以守卫要自己断言扫到了足够多的文件：
    /// 目录改名会让结果变成空数组，而"空数组"与"全部合格"在断言那里长得一样。
    static func productionSources() throws -> [(relativePath: String, text: String)] {
        let root = repositoryRoot
        var sources: [(relativePath: String, text: String)] = []

        for top in ["Shared", "App"] {
            let base = root.appending(path: top)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
            else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let relativePath = url.path.replacingOccurrences(of: root.path + "/", with: "")
                sources.append(
                    (relativePath: relativePath, text: try String(contentsOf: url, encoding: .utf8))
                )
            }
        }

        return sources.sorted { $0.relativePath < $1.relativePath }
    }

    /// 剔除**整行**注释后的代码行（带行号）。
    ///
    /// 只剔除以 `//` 开头的行，不做行内注释剥离 —— 后者要处理字符串里的 `//`
    /// （URL 就是），截错了会变成漏报。整行规则对当前代码成立，且不可能漏。
    static func codeLines(of text: String) -> [(number: Int, text: String)] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, line -> (number: Int, text: String)? in
                let value = String(line)
                return value.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                    ? nil
                    : (number: index + 1, text: value)
            }
    }

    /// 某条 pattern 在生产代码里的出现点，形如 `路径:行号`。
    static func occurrences(of needle: String) throws -> [String] {
        try productionSources().flatMap { source in
            codeLines(of: source.text)
                .filter { $0.text.contains(needle) }
                .map { "\(source.relativePath):\($0.number)" }
        }
    }
}
