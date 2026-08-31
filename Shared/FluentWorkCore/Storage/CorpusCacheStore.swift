import FluentWorkNetworking
import Foundation

public struct CachedCorpusSnapshot: Codable, Equatable, Sendable {
    public var items: [PhraseBlock]
    public var nextCursor: String?

    public init(items: [PhraseBlock], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public protocol CorpusCacheStoreProtocol: Sendable {
    func loadSnapshot(scope: String) async throws -> CachedCorpusSnapshot?
    func saveSnapshot(_ snapshot: CachedCorpusSnapshot, scope: String) async throws
    func clearSnapshot(scope: String) async throws
}

public actor JSONCorpusCacheStore: CorpusCacheStoreProtocol {
    private let directoryURL: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        directoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL ?? defaultCorpusCacheDirectoryURL()
        self.fileManager = fileManager
    }

    public func loadSnapshot(scope: String) async throws -> CachedCorpusSnapshot? {
        let fileURL = snapshotFileURL(scope: scope)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(CachedCorpusSnapshot.self, from: data)
    }

    public func saveSnapshot(_ snapshot: CachedCorpusSnapshot, scope: String) async throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try encoder.encode(snapshot)
        try data.write(to: snapshotFileURL(scope: scope), options: [.atomic])
    }

    public func clearSnapshot(scope: String) async throws {
        let fileURL = snapshotFileURL(scope: scope)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }
        try fileManager.removeItem(at: fileURL)
    }

    private func snapshotFileURL(scope: String) -> URL {
        directoryURL.appendingPathComponent("corpus-\(sanitizedScope(scope)).json")
    }

    private func sanitizedScope(_ scope: String) -> String {
        scope.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
        }
        .map(String.init)
        .joined()
    }
}

public actor InMemoryCorpusCacheStore: CorpusCacheStoreProtocol {
    private var snapshots: [String: CachedCorpusSnapshot] = [:]

    public init() {}

    public func loadSnapshot(scope: String) async throws -> CachedCorpusSnapshot? {
        return snapshots[scope]
    }

    public func saveSnapshot(_ snapshot: CachedCorpusSnapshot, scope: String) async throws {
        snapshots[scope] = snapshot
    }

    public func clearSnapshot(scope: String) async throws {
        snapshots.removeValue(forKey: scope)
    }
}

private func defaultCorpusCacheDirectoryURL() -> URL {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory
    return root
        .appendingPathComponent("FluentWork", isDirectory: true)
        .appendingPathComponent("CorpusCache", isDirectory: true)
}
