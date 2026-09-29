import Foundation

/// 快照缓存的机制层：按 scope 把一个 `Codable` 快照落到磁盘。
///
/// 语料库 / 历史 / 每日一读要的是同一件事 —— 原子写、按 scope 分文件、
/// scope 里不许出现路径分隔符、目录按需创建。机制写一遍，各域只声明
/// 「快照长什么样」和「文件前缀」。
///
/// 缓存是**只读展示**用的：它让弱网下进屏不留白页，不参与写回合并。
/// 语料库另有一套 outbox / tombstone 机制，那是编辑合并的问题，与本文件无关。
public actor JSONSnapshotStore<Snapshot: Codable & Sendable> {
    private let directoryURL: URL
    private let filePrefix: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// 不注入 `FileManager`：它不是 `Sendable`，把它交给本 actor 会让
    /// Swift 6 判成 data race（`sending 'fileManager' risks causing data races`）。
    /// 本文件只用到 `FileManager` 里线程安全的那几个操作（`fileExists` /
    /// `createDirectory` / `removeItem` 与 `Data(contentsOf:)` / `write(to:)`），
    /// 所以用 `.default` 即可，也没有哪个调用点在注入它。
    public init(
        filePrefix: String,
        directoryURL: URL? = nil
    ) {
        self.filePrefix = filePrefix
        self.directoryURL = directoryURL ?? defaultCorpusStateDirectoryURL()
    }

    public func load(scope: String) throws -> Snapshot? {
        let fileURL = fileURL(scope: scope)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return try decoder.decode(Snapshot.self, from: try Data(contentsOf: fileURL))
    }

    public func save(_ snapshot: Snapshot, scope: String) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try encoder.encode(snapshot).write(to: fileURL(scope: scope), options: [.atomic])
    }

    public func clear(scope: String) throws {
        let fileURL = fileURL(scope: scope)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: fileURL)
    }

    private func fileURL(scope: String) -> URL {
        directoryURL.appendingPathComponent("\(filePrefix)-\(sanitizedScope(scope)).json")
    }

    private func sanitizedScope(_ scope: String) -> String {
        scope.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
        }
        .map(String.init)
        .joined()
    }
}

/// `JSONSnapshotStore` 的内存版，供测试与预览使用。
public actor InMemorySnapshotStore<Snapshot: Codable & Sendable> {
    private var snapshots: [String: Snapshot] = [:]

    public init() {}

    public func load(scope: String) -> Snapshot? {
        snapshots[scope]
    }

    public func save(_ snapshot: Snapshot, scope: String) {
        snapshots[scope] = snapshot
    }

    public func clear(scope: String) {
        snapshots.removeValue(forKey: scope)
    }
}

/// 本地状态目录。
///
/// 目录名仍是 `CorpusState`：三个域共用它，改名会让既有安装里已经在盘上的
/// 语料库快照变成孤儿，收益不抵迁移成本。名字记的是历史，不是当前范围。
func defaultCorpusStateDirectoryURL() -> URL {
    let root =
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory
    return root
        .appendingPathComponent("FluentWork", isDirectory: true)
        .appendingPathComponent("CorpusState", isDirectory: true)
}
