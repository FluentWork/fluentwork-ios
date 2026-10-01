import Foundation

/// 双栏对照的**词级差异标注**（09-26 稿 屏 04：差异词用待改进色下划线标注而非红字）。
///
/// ## 它为什么是一个纯函数而不是视图里的一段
///
/// 「哪几个词算差异」有三处会错，而且错法都不一样：
///
/// 1. **把整句都标上** —— 最省事的做法是「只要两句不一样就全划线」，那样等于没标；
/// 2. **把标点/大小写算成差异** —— `"next week."` 与 `"next week"` 在学员眼里是同一件事；
/// 3. **拼回去不等于原文** —— 标注是**加在下划线上**的，不是改写句子。切片时丢一个空格、
///    吃掉一个逗号，屏幕上就会少字，而「少字」在这类高亮实现里是常见缺陷。
///
/// 三条都是可以写成判据的，所以规则住在这里（`ReviewTextDiffTests`）。
public enum ReviewTextDiff {

    /// 一段连续的标注片段。相邻且同标记的片段会合并 —— 视图少画几个 `Text` 拼接。
    public struct Segment: Equatable, Sendable {
        public var text: String
        /// 这一段是不是「差异词」。
        public var isChanged: Bool

        public init(text: String, isChanged: Bool) {
            self.text = text
            self.isChanged = isChanged
        }
    }

    /// 两侧各自的标注结果。
    ///
    /// 返回的是**词序列**而不是一整段富文本：视图把同一侧的所有片段拼着画，
    /// 于是「原文有没有变」这件事不依赖任何富文本 API。
    ///
    /// 算法是句子级的 LCS（最长公共子序列）：**两侧都出现的词算「没变」**，
    /// 其余算差异。用 LCS 而不是逐位置比较，是因为「插了一个词」会让后面每个位置都错开
    /// （`I will do` / `I'll get the` 逐位置比的话整句全变）。
    public static func segments(
        lhs: String,
        rhs: String
    ) -> (lhs: [Segment], rhs: [Segment]) {
        let leftTokens = tokenize(lhs)
        let rightTokens = tokenize(rhs)

        // 「差异」只在有词的 token 之间算：空白段永远不标（标了也看不见），
        // 而且它们的 key 都是空串，混进 LCS 会互相错误地配上。
        let leftKeys = leftTokens.map(\.key)
        let rightKeys = rightTokens.map(\.key)
        let leftDiffable = leftKeys.enumerated().filter { !$0.element.isEmpty }.map(\.offset)
        let rightDiffable = rightKeys.enumerated().filter { !$0.element.isEmpty }.map(\.offset)

        let matched = longestCommonSubsequence(
            leftDiffable.map { leftKeys[$0] },
            rightDiffable.map { rightKeys[$0] }
        )
        var matchedLeft = Set(matched.lhs.map { leftDiffable[$0] })
        var matchedRight = Set(matched.rhs.map { rightDiffable[$0] })
        _ = matchedLeft
        _ = matchedRight

        return (
            group(leftTokens, matchedIndices: matchedLeft),
            group(rightTokens, matchedIndices: matchedRight)
        )
    }

    // MARK: - 词

    private struct Token {
        /// 原文里的这一片（含它后面的空白）。
        var text: String
        /// 用来比大小的形式：小写、去掉首尾标点。空串表示这一片只是空白。
        var key: String
    }

    private static let tokenPattern = try? NSRegularExpression(pattern: "\\S+\\s*")

    /// 把一段话切成**恰好铺满原文**的 token。
    ///
    /// 「恰好铺满」是硬要求：`group` 之后片段拼起来必须还是原文（判据 `拼回来等于原文两侧`）。
    private static func tokenize(_ text: String) -> [Token] {
        guard !text.isEmpty else { return [] }
        guard let tokenPattern else {
            return [Token(text: text, key: normalizationKey(of: text))]
        }

        let ns = text as NSString
        var tokens: [Token] = []
        var cursor = 0

        for match in tokenPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                let leading = ns.substring(
                    with: NSRange(location: cursor, length: match.range.location - cursor)
                )
                tokens.append(Token(text: leading, key: ""))
            }
            let piece = ns.substring(with: match.range)
            tokens.append(Token(text: piece, key: normalizationKey(of: piece)))
            // **必须推进游标**：不推进的话，下一次匹配会把「从 0 到匹配起点」整段当成前导空白，
            // 于是每个 token 都带着从头累积的文本 —— 拼回去就是「I'll I'll get I'll get back …」。
            cursor = match.range.location + match.range.length
        }

        if cursor < ns.length {
            // 理论上到不了这里（`\S+\s*` 铺满整串），留着是为了「万一少了一片」也不丢字。
            tokens.append(Token(text: ns.substring(from: cursor), key: ""))
        }
        return tokens
    }

    /// 比大小的形式：小写 + 去掉首尾标点，**中间的标点保留**（`I'll` 不该变成 `Ill`）。
    private static func normalizationKey(of piece: String) -> String {
        let lowered = piece.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return "" }
        let isWordCharacter: (Character) -> Bool = { $0.isLetter || $0.isNumber }
        guard let first = lowered.firstIndex(where: isWordCharacter),
            let last = lowered.lastIndex(where: isWordCharacter),
            first <= last
        else {
            // 整片都是标点（例如 `"..."`）：它没有可比的形式，也不该被标成差异。
            return ""
        }
        return String(lowered[first...last])
    }

    // MARK: - LCS

    /// 返回两侧**都保留下来**的下标（在各自 diffable 子序列里的位置）。
    private static func longestCommonSubsequence(
        _ lhs: [String],
        _ rhs: [String]
    ) -> (lhs: [Int], rhs: [Int]) {
        let n = lhs.count
        let m = rhs.count
        guard n > 0, m > 0 else { return ([], []) }

        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] =
                    lhs[i] == rhs[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }

        var leftIndices: [Int] = []
        var rightIndices: [Int] = []
        var i = 0
        var j = 0
        while i < n, j < m {
            if lhs[i] == rhs[j] {
                leftIndices.append(i)
                rightIndices.append(j)
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return (leftIndices, rightIndices)
    }

    /// 切成片段并合并相邻的同标记片段。
    private static func group(_ tokens: [Token], matchedIndices: Set<Int>) -> [Segment] {
        var segments: [Segment] = []
        for (index, token) in tokens.enumerated() {
            // 空白片永远算「没变」—— 它上面的下划线看不见，标了只会让分段变碎。
            let isChanged = token.key.isEmpty ? false : !matchedIndices.contains(index)
            if var last = segments.last, last.isChanged == isChanged {
                last.text += token.text
                segments[segments.count - 1] = last
            } else {
                segments.append(Segment(text: token.text, isChanged: isChanged))
            }
        }
        return segments
    }
}
