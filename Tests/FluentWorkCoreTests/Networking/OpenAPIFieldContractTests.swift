import FluentWorkNetworking
import Foundation
import Testing

private enum ContractSource {
    case schema(String)
    case operation(method: String, path: String)
}

private struct ModelBinding {
    let swiftType: String
    let source: ContractSource
}

private let boundModels: [ModelBinding] = [
    ModelBinding(swiftType: "TokenResponse", source: .schema("TokenResponse")),
    ModelBinding(swiftType: "MergeResponse", source: .schema("MergeResponse")),
    ModelBinding(swiftType: "CreateSessionResponse", source: .schema("CreateSessionResponse")),
    ModelBinding(swiftType: "PostMessageResponse", source: .schema("PostMessageResponse")),
    ModelBinding(swiftType: "ReviewPollResponse", source: .schema("ReviewPollResponse")),
    ModelBinding(swiftType: "PhraseBlock", source: .schema("PhraseBlock")),
    ModelBinding(swiftType: "ListPhraseBlocksResponse", source: .schema("ListPhraseBlocksResponse")),
    ModelBinding(swiftType: "BatchAcceptBlocksResponse", source: .schema("BatchAcceptBlocksResponse")),
    ModelBinding(
        swiftType: "DeleteCorpusBlockResponse",
        source: .operation(method: "delete", path: "/corpus/blocks/{id}")),
    ModelBinding(swiftType: "DailyReadTodayResponse", source: .schema("DailyReadTodayResponse")),
    ModelBinding(swiftType: "DailyRead", source: .schema("DailyRead")),
    ModelBinding(swiftType: "FollowReadResponse", source: .schema("FollowReadResponse")),
    ModelBinding(swiftType: "DrillRound", source: .schema("DrillRound")),
    ModelBinding(swiftType: "DrillCard", source: .schema("DrillCard")),
    ModelBinding(swiftType: "DrillVerdict", source: .schema("DrillJudgeResponse")),
    ModelBinding(swiftType: "DrillAppealOutcome", source: .schema("DrillAppealResponse")),
    ModelBinding(swiftType: "SessionHistoryPage", source: .schema("SessionListPage")),
    ModelBinding(swiftType: "SessionHistoryItem", source: .schema("SessionListItem")),
    ModelBinding(swiftType: "SessionDetail", source: .schema("SessionDetail")),
    ModelBinding(swiftType: "SessionUtterance", source: .schema("SessionUtterance")),
    ModelBinding(swiftType: "TopicCardList", source: .schema("TopicCardList")),
    ModelBinding(swiftType: "TopicCheckinResult", source: .schema("TopicCheckinResult")),
    ModelBinding(swiftType: "TopicPracticeStats", source: .schema("TopicPracticeStats")),
    ModelBinding(swiftType: "TopicDismissResult", source: .schema("TopicDismissResult")),
]

private let decodedTypesWithoutRESTBinding: [String: String] = [
    "APIErrorBody": "错误响应体，键面归契约的 Error schema；NetworkClient 单独解它",
    "WSControlFrame": "WSS 控制帧，不在 REST 契约里；由 wss-control-frames-v2 镜像与 PackageBaselineTests 管",
]

@Test func everyKeyTheClientReadsIsDeclaredInTheContract() throws {
    let sources = try networkingSources()
    let contract = try openAPIContract()
    var checkedKeys = 0

    for binding in boundModels {
        let keys = try clientKeys(of: binding.swiftType, in: sources)
        #expect(!keys.isEmpty, "\(binding.swiftType) 一个键都没解析出来 —— 类型没找到或解析器失配")

        let declared = try contractKeys(of: binding.source, in: contract)
        #expect(!declared.isEmpty, "\(binding.swiftType) 对应的契约节点没解析出属性")
        checkedKeys += keys.count

        let undeclared = keys.subtracting(declared).sorted()
        #expect(
            undeclared.isEmpty,
            """
            \(binding.swiftType) 读的这些键，契约没声明：\(undeclared) —— \
            客户端会去读一个契约里不存在的字段（record_id 那类缺陷就是这样漏出去的）
            """
        )
    }

    #expect(
        checkedKeys >= 80,
        "只查了 \(checkedKeys) 个键 —— 映射表或解析器失配，这条判据正在空转"
    )
}

@Test func theModelTableCoversEveryTypeTheClientsDecode() throws {
    let sources = try networkingSources()
    let decoded = decodedTypes(in: sources)
    let bound = Set(boundModels.map(\.swiftType))
    let exempt = Set(decodedTypesWithoutRESTBinding.keys)

    let uncovered = decoded.subtracting(bound).subtracting(exempt).sorted()
    #expect(
        uncovered.isEmpty,
        "这些类型被 decode 了但没进映射表：\(uncovered) —— 加模型时要一起声明它对应的契约 schema"
    )

    let stale = exempt.filter { !decoded.contains($0) }.sorted()
    #expect(stale.isEmpty, "豁免名单里这些已经不再被 decode 了：\(stale)")

    #expect(decoded.count >= 14, "只扫到 \(decoded.count) 个解码类型 —— 扫描器失配")
}

@Test func everyBindingResolvesToARealContractNode() throws {
    let contract = try openAPIContract()
    for binding in boundModels {
        let declared = try contractKeys(of: binding.source, in: contract)
        #expect(
            !declared.isEmpty,
            "\(binding.swiftType) 绑的契约节点不存在或没有 properties：\(binding.source)"
        )
    }
}

private func networkingSources() throws -> [String: String] {
    var sources: [String: String] = [:]
    for url in try swiftFiles(under: "Shared/FluentWorkNetworking") {
        sources[url.lastPathComponent] = try String(contentsOf: url, encoding: .utf8)
    }
    return sources
}

private func decodedTypes(in sources: [String: String]) -> Set<String> {
    let primitives: Set<String> = ["String", "Int", "Int64", "Bool", "Double", "Date", "T"]
    var found: Set<String> = []
    let patterns = [
        "decode\\(\\s*([A-Z][A-Za-z0-9]*)\\s*\\.self\\s*,\\s*\\.",
        "\\.decode\\(\\s*([A-Z][A-Za-z0-9]*)\\s*\\.self\\s*,\\s*from:",
    ]
    for source in sources.values {
        for pattern in patterns {
            let regex = try? NSRegularExpression(pattern: pattern)
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in regex?.matches(in: source, range: range) ?? [] {
                guard let captured = Range(match.range(at: 1), in: source) else { continue }
                let name = String(source[captured])
                if !primitives.contains(name) { found.insert(name) }
            }
        }
    }
    return found
}

private func clientKeys(of typeName: String, in sources: [String: String]) throws -> Set<String> {
    guard let block = try typeBlock(typeName, in: sources) else { return [] }
    if let keys = codingKeys(in: block) { return keys }
    return storedPropertyNames(in: block)
}

private func typeBlock(_ typeName: String, in sources: [String: String]) throws -> String? {
    for source in sources.values {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("public struct \(typeName):")
                || trimmed.hasPrefix("public struct \(typeName) ")
                || trimmed == "public struct \(typeName) {"
            else { continue }
            let end = try braceEnd(lines, from: index)
            return lines[index...end].joined(separator: "\n")
        }
    }
    return nil
}

private func codingKeys(in block: String) -> Set<String>? {
    let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let start = lines.firstIndex(where: { $0.contains("enum CodingKeys") }) else { return nil }
    let end = try? braceEnd(lines, from: start)
    guard let end else { return nil }
    var keys: Set<String> = []
    for line in lines[start...end] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("case ") else { continue }
        let body = trimmed.dropFirst("case ".count)
        for part in body.split(separator: ",") {
            let pieces = part.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if pieces.count == 2 {
                let raw = pieces[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if !raw.isEmpty { keys.insert(raw) }
            } else if let name = pieces.first, !name.isEmpty {
                keys.insert(name)
            }
        }
    }
    return keys
}

private func storedPropertyNames(in block: String) -> Set<String> {
    var names: Set<String> = []
    for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = String(line).trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("public var ") || trimmed.hasPrefix("public let ") else {
            continue
        }
        guard !trimmed.contains("{"), !trimmed.contains("static") else { continue }
        let rest = trimmed.dropFirst("public var ".count)
        let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        if !name.isEmpty { names.insert(String(name)) }
    }
    return names
}

private func contractKeys(of source: ContractSource, in contract: String) throws -> Set<String> {
    let block: String
    switch source {
    case .schema(let name):
        guard let found = try schemaBlock(name, in: contract) else { return [] }
        block = found
    case .operation(let method, let path):
        guard let found = try operationBlock(method: method, path: path, in: contract) else {
            return []
        }
        block = found
    }
    return declaredProperties(in: block)
}

private func declaredProperties(in block: String) -> Set<String> {
    let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard
        let propertiesLine = lines.first(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("properties:")
        })
    else { return [] }
    let base = indent(of: propertiesLine) + 2
    var keys: Set<String> = []
    for line in lines.drop(while: { $0 != propertiesLine }).dropFirst() {
        let depth = indent(of: line)
        if depth <= indent(of: propertiesLine) { break }
        guard depth == base else { continue }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let name = trimmed.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        guard !name.isEmpty, trimmed.dropFirst(name.count).hasPrefix(":") else { continue }
        keys.insert(String(name))
    }
    return keys
}

private func schemaBlock(_ name: String, in contract: String) throws -> String? {
    let lines = contract.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let start = lines.firstIndex(where: { $0 == "    \(name):" }) else { return nil }
    return lines[start...endOfBlock(lines, from: start, indent: 4)].joined(separator: "\n")
}

private func operationBlock(method: String, path: String, in contract: String) throws -> String? {
    let lines = contract.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let pathStart = lines.firstIndex(where: { $0 == "  \(path):" }) else { return nil }
    let pathEnd = endOfBlock(lines, from: pathStart, indent: 2)
    guard
        let methodStart = lines[pathStart...pathEnd].firstIndex(where: {
            $0 == "    \(method):"
        })
    else { return nil }
    return lines[methodStart...endOfBlock(lines, from: methodStart, indent: 4)].joined(
        separator: "\n")
}

private func endOfBlock(_ lines: [String], from start: Int, indent base: Int) -> Int {
    var end = start
    for index in (start + 1)..<lines.count {
        let line = lines[index]
        if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
        if indent(of: line) <= base { break }
        end = index
    }
    return end
}

private func indent(of line: String) -> Int {
    line.prefix { $0 == " " }.count
}

private func braceEnd(_ lines: [String], from start: Int) throws -> Int {
    var depth = 0
    var seen = false
    for index in start..<lines.count {
        depth += lines[index].filter { $0 == "{" }.count
        depth -= lines[index].filter { $0 == "}" }.count
        if lines[index].contains("{") { seen = true }
        if seen, depth <= 0 { return index }
    }
    throw CocoaError(.validationMissingMandatoryProperty)
}

private func swiftFiles(under relativePath: String) throws -> [URL] {
    let base = repositoryRoot.appending(path: relativePath)
    guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
    else { return [] }
    return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
}

private func openAPIContract() throws -> String {
    try String(
        contentsOf: repositoryRoot.appending(
            path: "Shared/FluentWorkCore/Resources/Schemas/openapi-v1.yaml"),
        encoding: .utf8
    )
}

private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
