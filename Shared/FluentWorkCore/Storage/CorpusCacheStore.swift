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
    private let store: JSONSnapshotStore<CachedCorpusSnapshot>

    public init(directoryURL: URL? = nil) {
        store = JSONSnapshotStore(filePrefix: "corpus", directoryURL: directoryURL)
    }

    public func loadSnapshot(scope: String) async throws -> CachedCorpusSnapshot? {
        try await store.load(scope: scope)
    }

    public func saveSnapshot(_ snapshot: CachedCorpusSnapshot, scope: String) async throws {
        try await store.save(snapshot, scope: scope)
    }

    public func clearSnapshot(scope: String) async throws {
        try await store.clear(scope: scope)
    }
}

public actor InMemoryCorpusCacheStore: CorpusCacheStoreProtocol {
    private let store = InMemorySnapshotStore<CachedCorpusSnapshot>()

    public init() {}

    public func loadSnapshot(scope: String) async throws -> CachedCorpusSnapshot? {
        await store.load(scope: scope)
    }

    public func saveSnapshot(_ snapshot: CachedCorpusSnapshot, scope: String) async throws {
        await store.save(snapshot, scope: scope)
    }

    public func clearSnapshot(scope: String) async throws {
        await store.clear(scope: scope)
    }
}
