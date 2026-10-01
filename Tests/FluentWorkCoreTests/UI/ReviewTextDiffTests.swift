import Foundation
import Testing

@testable import FluentWorkUI

/// `ReviewTextDiff` —— 双栏对照的差异标注。
///
/// 稿子 屏 04 的原话：「左『你说的』/ 右『更地道的版本』，**差异词用待改进色下划线标注
/// 而非红字**」。一个词被标上，学员就会去琢磨它 —— 所以标错的代价是让人改对的地方。
/// 这一组判据盯的是三件事：**该标的标、不该标的不标、拼回来还是原文**。
@Suite("双栏对照的差异标注")
struct ReviewTextDiffTests {

    private func plain(_ text: String) -> String {
        text
    }

    /// 把片段拼回去。**这是这一组里最要紧的一条**：标注是加在字下面的下划线，
    /// 不是改写句子 —— 丢一个空格、吃掉一个逗号，屏幕上就少字。
    private func rebuilt(_ segments: [ReviewTextDiff.Segment]) -> String {
        segments.map(\.text).joined()
    }

    private func changedWords(_ segments: [ReviewTextDiff.Segment]) -> [String] {
        segments
            .filter(\.isChanged)
            .flatMap { $0.text.split(separator: " ").map(String.init) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 稿子里那一对原句。
    private var compPair: (lhs: String, rhs: String) {
        (
            "I will do the cache thing next week.",
            "I'll get the caching work wrapped up next week."
        )
    }

    @Test func 拼回来等于原文两侧() {
        let pair = compPair
        let result = ReviewTextDiff.segments(lhs: pair.lhs, rhs: pair.rhs)

        #expect(rebuilt(result.lhs) == pair.lhs, "左侧被改写成了：\(rebuilt(result.lhs))")
        #expect(rebuilt(result.rhs) == pair.rhs, "右侧被改写成了：\(rebuilt(result.rhs))")
    }

    /// **两边都有的词不高亮**。「next week.」两侧都在，它不该被标 ——
    /// 全标等于没标，而「哪几个词是这次要改的」正是这一屏的冲击力所在。
    @Test func 两边都有的词不高亮() {
        let pair = compPair
        let result = ReviewTextDiff.segments(lhs: pair.lhs, rhs: pair.rhs)

        #expect(changedWords(result.rhs).contains("next") == false, "next 两侧都有")
        #expect(changedWords(result.rhs).contains("week.") == false, "week. 两侧都有（标点不该让它变成差异）")
        #expect(
            changedWords(result.rhs).isEmpty == false,
            "整句都不一样却一个词都没标 —— 那这一层标注就是个摆设"
        )
    }

    /// 只在一边出现的表达要被标出来：右侧的 `caching` / `wrapped up`，左侧的 `cache` / `thing`。
    @Test func 只在一边出现的词被标出来() {
        let pair = compPair
        let result = ReviewTextDiff.segments(lhs: pair.lhs, rhs: pair.rhs)
        let left = changedWords(result.lhs)
        let right = changedWords(result.rhs)

        #expect(right.contains("caching"), "右侧标出来的：\(right)")
        #expect(right.contains("wrapped") || right.contains("up"), "右侧标出来的：\(right)")
        #expect(left.contains("cache"), "左侧标出来的：\(left)")
        #expect(left.contains("thing"), "左侧标出来的：\(left)")
    }

    /// 大小写与标点**不算差异**：学员要改的是用词，不是大小写。
    @Test func 大小写与标点不算差异() {
        let result = ReviewTextDiff.segments(
            lhs: "Let's push the launch.",
            rhs: "let's push the launch"
        )

        #expect(changedWords(result.lhs).isEmpty, "只差大小写与句号，却被标成：\(changedWords(result.lhs))")
        #expect(changedWords(result.rhs).isEmpty)
    }

    /// 一模一样的两句：两边都不标。
    @Test func 完全相同的两句一个字都不标() {
        let same = "I'll get back to you tomorrow."
        let result = ReviewTextDiff.segments(lhs: same, rhs: same)

        #expect(changedWords(result.lhs).isEmpty)
        #expect(changedWords(result.rhs).isEmpty)
        #expect(rebuilt(result.lhs) == same)
    }

    /// 只差一个词：只标那一个，其余保持干净。
    ///
    /// 左侧标出来的是 `I` **和** `will`（两者相邻，会合成一段）—— 这不是过度标注：
    /// `I will` 与 `I'll` 确实是两处不同，把它拆开标反而要靠「猜」。
    @Test func 只差一个词时只标那一个() {
        let result = ReviewTextDiff.segments(
            lhs: "I will handle it.",
            rhs: "I'll handle it."
        )

        #expect(changedWords(result.rhs) == ["I'll"], "右侧应当只标 I'll：\(changedWords(result.rhs))")
        #expect(changedWords(result.lhs).contains("will"), "左侧应当标出 will：\(changedWords(result.lhs))")
        #expect(
            changedWords(result.lhs).contains("handle") == false,
            "handle 两侧都在，不该被标：\(changedWords(result.lhs))"
        )
    }

    /// 空的一侧：没有字可标，也不该崩。
    @Test func 有一侧是空的() {
        let result = ReviewTextDiff.segments(lhs: "", rhs: "I'll wrap it up.")

        #expect(result.lhs.isEmpty)
        #expect(rebuilt(result.rhs) == "I'll wrap it up.")

        let bothEmpty = ReviewTextDiff.segments(lhs: "", rhs: "")
        #expect(bothEmpty.lhs.isEmpty && bothEmpty.rhs.isEmpty)
    }

    /// 相邻的同标记片段要合并 —— 否则一串 `Text` 拼接会让下划线在词间断开。
    @Test func 相邻同标记的片段被合并() {
        let result = ReviewTextDiff.segments(
            lhs: "do the cache thing",
            rhs: "get the caching work"
        )

        for segments in [result.lhs, result.rhs] {
            let flags = segments.map(\.isChanged)
            #expect(
                zip(flags, flags.dropFirst()).allSatisfy { $0 != $1 },
                "有相邻的同标记片段没合并：\(segments.map { ($0.text, $0.isChanged) })"
            )
        }
    }

    /// 一个词两侧各出现一次以上时，**出现顺序也要对**：
    /// 「我下一周看一下，下周给你回话」这类重复词不该让整句中段被吞成一团高亮。
    @Test func 重复出现的词不会吞掉中间() {
        let lhs = "I will check next week and next sprint."
        let rhs = "I'll check next week and next quarter."
        let result = ReviewTextDiff.segments(lhs: lhs, rhs: rhs)

        #expect(rebuilt(result.lhs) == lhs)
        #expect(rebuilt(result.rhs) == rhs)
        #expect(
            changedWords(result.rhs).contains("next") == false,
            "next 两侧都在，不该被标：\(changedWords(result.rhs))"
        )
    }
}
