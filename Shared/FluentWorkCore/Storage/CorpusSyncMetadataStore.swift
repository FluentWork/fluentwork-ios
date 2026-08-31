import Foundation

public struct CorpusSyncMetadata: Codable, Equatable, Sendable {
    public var listCursor: String?
    public var syncCursor: String?

    public init(listCursor: String? = nil, syncCursor: String? = nil) {
        self.listCursor = listCursor
        self.syncCursor = syncCursor
    }
}

public protocol CorpusSyncMetadataStoreProtocol: Sendable {
    func load(scope: String) async throws -> CorpusSyncMetadata?
    func save(_ metadata: CorpusSyncMetadata, scope: String) async throws
    func clear(scope: String) async throws
}

public actor JSONCorpusSyncMetadataStore: CorpusSyncMetadataStoreProtocol {
    private let directoryURL: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        directoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL ?? defaultCorpusStateDirectoryURL()
        self.fileManager = fileManager
    }

    public func load(scope: String) async throws -> CorpusSyncMetadata? {
        let fileURL = fileURL(scope: scope)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(CorpusSyncMetadata.self, from: data)
    }

    public func save(_ metadata: CorpusSyncMetadata, scope: String) async throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try encoder.encode(metadata)
        try data.write(to: fileURL(scope: scope), options: [.atomic])
    }

    public func clear(scope: String) async throws {
        let fileURL = fileURL(scope: scope)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }
        try fileManager.removeItem(at: fileURL)
    }

    private func fileURL(scope: String) -> URL {
        directoryURL.appendingPathComponent("corpus-sync-\(sanitizedScope(scope)).json")
    }

    private func sanitizedScope(_ scope: String) -> String {
        scope.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
        }
        .map(String.init)
        .joined()
    }
}

public actor InMemoryCorpusSyncMetadataStore: CorpusSyncMetadataStoreProtocol {
    private var metadataByScope: [String: CorpusSyncMetadata] = [:]

    public init() {}

    public func load(scope: String) async throws -> CorpusSyncMetadata? {
        metadataByScope[scope]
    }

    public func save(_ metadata: CorpusSyncMetadata, scope: String) async throws {
        metadataByScope[scope] = metadata
    }

    public func clear(scope: String) async throws {
        metadataByScope.removeValue(forKey: scope)
    }
}

func defaultCorpusStateDirectoryURL() -> URL {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory
    return root
        .appendingPathComponent("FluentWork", isDirectory: true)
        .appendingPathComponent("CorpusState", isDirectory: true)
}
