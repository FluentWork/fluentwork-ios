import FluentWorkNetworking
import Foundation
import Testing

private let placeholderID = "CONTRACT-PROBE-ID"

private struct ClientOperation {
    let name: String
    let api: FluentWorkAPI
    let path: String
    let method: String
}

private func blockRequest() -> CorpusBatchAcceptBlockRequest {
    CorpusBatchAcceptBlockRequest(
        intentZH: "i",
        expressionEN: "e",
        anchorUserSaid: "a",
        sceneTag: "s",
        functionTag: "f"
    )
}

private func updateRequest() -> UpdateCorpusBlockRequest {
    UpdateCorpusBlockRequest(
        intentZH: "i",
        expressionEN: "e",
        anchorUserSaid: "a",
        sceneTag: "s",
        functionTag: "f"
    )
}

private let clientOperations: [ClientOperation] = [
    ClientOperation(
        name: "issueGuest", api: .issueGuest(deviceID: placeholderID),
        path: "/auth/guest", method: "POST"),
    ClientOperation(
        name: "mergeGuestAccount",
        api: .mergeGuestAccount(deviceID: placeholderID, accessToken: "t"),
        path: "/account/merge", method: "POST"),
    ClientOperation(
        name: "refreshToken", api: .refreshToken(refreshToken: "t"),
        path: "/auth/refresh", method: "POST"),
    ClientOperation(
        name: "createSession",
        api: .createSession(accessToken: "t", materialID: nil, sceneType: nil),
        path: "/sessions", method: "POST"),
    ClientOperation(
        name: "getSessionReview",
        api: .getSessionReview(sessionID: placeholderID, accessToken: "t"),
        path: "/sessions/{id}/review", method: "GET"),
    ClientOperation(
        name: "sendSessionMessage",
        api: .sendSessionMessage(sessionID: placeholderID, accessToken: "t", text: "x"),
        path: "/sessions/{id}/messages", method: "POST"),
    ClientOperation(
        name: "listCorpusBlocks", api: .listCorpusBlocks(accessToken: "t"),
        path: "/corpus/blocks", method: "GET"),
    ClientOperation(
        name: "listSessions", api: .listSessions(accessToken: "t"),
        path: "/sessions", method: "GET"),
    ClientOperation(
        name: "getSessionDetail",
        api: .getSessionDetail(sessionID: placeholderID, accessToken: "t"),
        path: "/sessions/{id}", method: "GET"),
    ClientOperation(
        name: "batchAcceptCorpusBlocks",
        api: .batchAcceptCorpusBlocks(
            accessToken: "t", sourceSessionID: placeholderID, blocks: [blockRequest()]),
        path: "/corpus/blocks/batch-accept", method: "POST"),
    ClientOperation(
        name: "updateCorpusBlock",
        api: .updateCorpusBlock(
            accessToken: "t", blockID: placeholderID, request: updateRequest()),
        path: "/corpus/blocks/{id}", method: "PUT"),
    ClientOperation(
        name: "deleteCorpusBlock",
        api: .deleteCorpusBlock(accessToken: "t", blockID: placeholderID),
        path: "/corpus/blocks/{id}", method: "DELETE"),
    ClientOperation(
        name: "favoriteCorpusBlock",
        api: .favoriteCorpusBlock(
            accessToken: "t", blockID: placeholderID, isFavorite: true, pinned: false),
        path: "/corpus/blocks/{id}/favorite", method: "POST"),
    ClientOperation(
        name: "getDailyReadToday", api: .getDailyReadToday(accessToken: "t"),
        path: "/daily-reads/today", method: "GET"),
    ClientOperation(
        name: "postDailyReadFollowRead",
        api: .postDailyReadFollowRead(
            accessToken: "t", dailyReadID: placeholderID, audioURL: nil),
        path: "/daily-reads/{id}/follow-read", method: "POST"),
    ClientOperation(
        name: "drillRound", api: .drillRound(accessToken: "t", size: 10),
        path: "/drill/round", method: "GET"),
    ClientOperation(
        name: "drillJudge",
        api: .drillJudge(
            accessToken: "t", blockID: placeholderID, asrText: "x", responseMS: 1,
            sessionID: nil),
        path: "/drill/judge", method: "POST"),
    ClientOperation(
        name: "drillAppeal", api: .drillAppeal(accessToken: "t", recordID: 1),
        path: "/drill/appeal", method: "POST"),
    ClientOperation(
        name: "topicCards", api: .topicCards(accessToken: "t"),
        path: "/topic-cards", method: "GET"),
    ClientOperation(
        name: "topicCheckin",
        api: .topicCheckin(
            accessToken: "t",
            cardID: placeholderID,
            request: TopicCheckinRequest(reflection: "r", usedBlockIDs: [])
        ),
        path: "/topic-cards/{id}/checkin", method: "POST"),
    ClientOperation(
        name: "topicStats", api: .topicStats(accessToken: "t", days: 7),
        path: "/topic-cards/stats", method: "GET"),
    ClientOperation(
        name: "topicDismiss",
        api: .topicDismiss(accessToken: "t", cardID: placeholderID, reason: .noTime),
        path: "/topic-cards/{id}/dismiss", method: "POST"),
    // 屏 11 的「一句话描述」/「粘贴素材」建素材走的就是这一条。契约里一直有它
    // （`operationId: createMaterial`），只是客户端此前从没调过。
    ClientOperation(
        name: "createMaterial",
        api: .createMaterial(accessToken: "t", kind: "sentence", content: "x"),
        path: "/materials", method: "POST"),
]

@Test func everyClientOperationIsDeclaredInTheMirroredContract() throws {
    let declared = contractOperations(try openAPIContract())
    #expect(
        declared.count >= 30,
        "只解析出 \(declared.count) 条操作 —— 契约镜像没读进来，或者解析器失配")

    for operation in clientOperations {
        let normalized = operation.api.path.replacingOccurrences(
            of: placeholderID,
            with: "{id}"
        )
        #expect(
            normalized == operation.path,
            "\(operation.name) 代码里的 path 是 \(normalized)，对照表写的是 \(operation.path)"
        )
        #expect(
            operation.api.method.rawValue == operation.method,
            "\(operation.name) 代码里的方法是 \(operation.api.method.rawValue)，对照表写的是 \(operation.method)"
        )
        #expect(
            declared.contains("\(operation.method) \(operation.path)"),
            "\(operation.name) 调 \(operation.method) \(operation.path)，但契约里没有这一条 —— 线上会拿到 404"
        )
    }
}

@Test func theOperationTableCoversEveryCaseInTheSource() throws {
    let source = try repositoryFile("Shared/FluentWorkNetworking/API/FluentWorkAPI.swift")
    let inSource = caseNames(in: source)
    let listed = clientOperations.map(\.name)

    let missing = Set(inSource).subtracting(listed).sorted()
    let extra = Set(listed).subtracting(inSource).sorted()
    #expect(
        missing.isEmpty,
        "FluentWorkAPI 里这些 case 没有进对照表：\(missing) —— 加 case 时要一起声明它对应的契约路径"
    )
    #expect(extra.isEmpty, "对照表里有源码中不存在的 case：\(extra)")
    #expect(inSource.count == listed.count)
}

@Test func theMirroredContractCoversTheOperationsTheClientUses() throws {
    let declared = contractOperations(try openAPIContract())
    let used = Set(clientOperations.map { "\($0.method) \($0.path)" })
    let uncovered = used.subtracting(declared).sorted()
    #expect(uncovered.isEmpty, "客户端在用但契约没声明的操作：\(uncovered)")
    #expect(declared.count > used.count, "契约应当比客户端用到的操作更多（有未消费的端点）")
}

private func caseNames(in source: String) -> [String] {
    var names: [String] = []
    for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
        let text = String(line)
        guard text.hasPrefix("  case "), !text.hasPrefix("  case .") else { continue }
        let rest = text.dropFirst("  case ".count)
        let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        if !name.isEmpty { names.append(String(name)) }
    }
    return names
}

private func contractOperations(_ yaml: String) -> Set<String> {
    let methods: Set<String> = ["get", "post", "put", "delete", "patch", "head", "options"]
    var operations: Set<String> = []
    var currentPath: String?
    var inPaths = false

    for line in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
        let text = String(line)
        if text == "paths:" {
            inPaths = true
            continue
        }
        guard inPaths else { continue }
        if !text.hasPrefix(" ") {
            inPaths = false
            currentPath = nil
            continue
        }
        if text.hasPrefix("  /"), text.hasSuffix(":") {
            currentPath = String(text.dropFirst(2).dropLast())
            continue
        }
        guard text.hasPrefix("    "), let path = currentPath else { continue }
        let key = text.trimmingCharacters(in: .whitespaces)
        guard key.hasSuffix(":") else { continue }
        let name = String(key.dropLast())
        if methods.contains(name) {
            operations.insert("\(name.uppercased()) \(path)")
        }
    }
    return operations
}

private func openAPIContract() throws -> String {
    try repositoryFile("Shared/FluentWorkCore/Resources/Schemas/openapi-v1.yaml")
}

private func repositoryFile(_ relativePath: String) throws -> String {
    let url = repositoryRoot.appending(path: relativePath)
    return try String(contentsOf: url, encoding: .utf8)
}

private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
