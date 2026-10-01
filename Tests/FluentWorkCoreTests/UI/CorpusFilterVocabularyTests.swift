import Foundation
import Testing

@testable import FluentWorkUI

/// **两个筛选维度的取值必须与契约逐字一致。**
///
/// 场景与功能是**闭集**：契约里 `PhraseBlock.scene_tag` / `function_tag` 写着 `enum`，
/// 服务端也用同一份闭集校验写入。所以 iOS 侧这张表不是「我们定义的一套标签」，
/// 而是那份闭集的镜像 —— 而**手抄的镜像会漂**：后端加一个标签，这里什么都不说，
/// 直到有人在真机上发现「有个场景筛不出来」。
///
/// 判据读的是仓里那份**vendored 契约**（`Resources/Schemas/openapi-v1.yaml`，由
/// `Scripts/sync-shared-schemas.sh` 从后端同步），所以它是真的对着来源在核，不是自说自话。
@Suite("语料库筛选词表")
struct CorpusFilterVocabularyTests {

    private func contractEnum(for field: String) throws -> [String] {
        let text = try String(
            contentsOf: repositoryRoot.appending(
                path: "Shared/FluentWorkCore/Resources/Schemas/openapi-v1.yaml"),
            encoding: .utf8
        )
        // `field:\n  type: string\n  enum: [a, b, c]` —— 契约里这一段的写法固定，
        // 所以按行切够用，也不必引一个 YAML 解析器。
        let pattern = "\(field):\\s*\\n\\s*type: string\\s*\\n\\s*enum: \\[([^\\]]+)\\]"
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
            let captured = Range(match.range(at: 1), in: text)
        else {
            Issue.record("契约里没找到 \(field) 的 enum —— 解析器失配，或者它不再是一个闭集了")
            return []
        }
        return text[captured]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    @Test func 场景词表与契约一致() throws {
        let fromContract = try contractEnum(for: "scene_tag")
        #expect(!fromContract.isEmpty, "解析器读空了 —— 这条判据在空转")

        let ours = CorpusSceneFilter.allCases.map(\.serverTag)
        #expect(
            ours == fromContract,
            """
            iOS 的场景词表与契约不一致。
            契约：\(fromContract)
            iOS ：\(ours)
            多出来的筛出来永远是空的，少掉的永远筛不到。
            """
        )
    }

    @Test func 功能词表与契约一致() throws {
        let fromContract = try contractEnum(for: "function_tag")
        #expect(!fromContract.isEmpty, "解析器读空了 —— 这条判据在空转")

        let ours = CorpusFunctionFilter.allCases.map(\.serverTag)
        #expect(
            ours == fromContract,
            """
            iOS 的功能词表与契约不一致。
            契约：\(fromContract)
            iOS ：\(ours)
            """
        )
    }

    /// 中文标签两两不同 —— 否则 chips 上会出现两个一模一样的按钮，点哪个都说不清。
    @Test func 两个维度的中文标签各自两两不同() {
        let scenes = CorpusSceneFilter.allCases.map(\.label)
        let functions = CorpusFunctionFilter.allCases.map(\.label)

        #expect(Set(scenes).count == scenes.count, "场景标签撞了：\(scenes)")
        #expect(Set(functions).count == functions.count, "功能标签撞了：\(functions)")
        #expect(scenes.allSatisfy { !$0.isEmpty })
        #expect(functions.allSatisfy { !$0.isEmpty })
    }
}

private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // UI
        .deletingLastPathComponent()  // FluentWorkCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root
}
