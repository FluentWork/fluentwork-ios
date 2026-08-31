import Foundation

public enum CorpusOutboxOperation: String, Codable, Equatable, Sendable {
    case favorite
    case delete
}

public struct CorpusOutboxItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var blockID: String
    public var operation: CorpusOutboxOperation
    public var payload: Payload
    public var retryCount: Int
    public var createdAt: String

    public struct Payload: Codable, Equatable, Sendable {
        public var isFavorite: Bool?
        public var pinned: Bool?

        public init(isFavorite: Bool? = nil, pinned: Bool? = nil) {
            self.isFavorite = isFavorite
            self.pinned = pinned
        }
    }

    public init(
        id: String,
        blockID: String,
        operation: CorpusOutboxOperation,
        payload: Payload,
        retryCount: Int,
        createdAt: String
    ) {
        self.id = id
        self.blockID = blockID
        self.operation = operation
        self.payload = payload
        self.retryCount = retryCount
        self.createdAt = createdAt
    }
}

public protocol CorpusOutboxStoreProtocol: Sendable {
    func loadItems(scope: String) async throws -> [CorpusOutboxItem]
    func saveItems(_ items: [CorpusOutboxItem], scope: String) async throws
    func clearItems(scope: String) async throws
}

public actor JSONCorpusOutboxStore: CorpusOutboxStoreProtocol {
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

    public func loadItems(scope: String) async throws -> [CorpusOutboxItem] {
        let fileURL = fileURL(scope: scope)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([CorpusOutboxItem].self, from: data)
    }

    public func saveItems(_ items: [CorpusOutboxItem], scope: String) async throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try encoder.encode(items)
        try data.write(to: fileURL(scope: scope), options: [.atomic])
    }

    public func clearItems(scope: String) async throws {
        let fileURL = fileURL(scope: scope)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }
        try fileManager.removeItem(at: fileURL)
    }

    private func fileURL(scope: String) -> URL {
        directoryURL.appendingPathComponent("corpus-outbox-\(sanitizedScope(scope)).json")
    }

    private func sanitizedScope(_ scope: String) -> String {
        scope.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
        }
        .map(String.init)
        .joined()
    }
}

public actor InMemoryCorpusOutboxStore: CorpusOutboxStoreProtocol {
    private var itemsByScope: [String: [CorpusOutboxItem]] = [:]

    public init() {}

    public func loadItems(scope: String) async throws -> [CorpusOutboxItem] {
        itemsByScope[scope] ?? []
    }

    public func saveItems(_ items: [CorpusOutboxItem], scope: String) async throws {
        itemsByScope[scope] = items
    }

    public func clearItems(scope: String) async throws {
        itemsByScope.removeValue(forKey: scope)
    }
}
