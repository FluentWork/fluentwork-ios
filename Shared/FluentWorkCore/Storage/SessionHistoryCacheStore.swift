import FluentWorkNetworking
import Foundation

/// 历史列表的**只读展示**缓存：弱网下进屏不留白页（稿子 §07 场景 06）。
///
/// 它不参与写回合并，也不该参与 —— 会话存在服务端的 `practice_sessions` 里，
/// 客户端不编辑它，所以这里没有 outbox、没有 tombstone、没有 merge 重建。
/// 那套机制是「本地也改了，两边要对账」才需要的，语料库有，这里没有。
public struct CachedSessionHistorySnapshot: Codable, Equatable, Sendable {
    public var items: [SessionHistoryItem]
    public var nextCursor: String?

    public init(items: [SessionHistoryItem], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public protocol SessionHistoryCacheStoreProtocol: Sendable {
    func loadSnapshot(scope: String) async throws -> CachedSessionHistorySnapshot?
    func saveSnapshot(_ snapshot: CachedSessionHistorySnapshot, scope: String) async throws
    func clearSnapshot(scope: String) async throws
}

public actor JSONSessionHistoryCacheStore: SessionHistoryCacheStoreProtocol {
    private let store: JSONSnapshotStore<CachedSessionHistorySnapshot>

    public init(directoryURL: URL? = nil) {
        store = JSONSnapshotStore(filePrefix: "session-history", directoryURL: directoryURL)
    }

    public func loadSnapshot(scope: String) async throws -> CachedSessionHistorySnapshot? {
        try await store.load(scope: scope)
    }

    public func saveSnapshot(_ snapshot: CachedSessionHistorySnapshot, scope: String) async throws {
        try await store.save(snapshot, scope: scope)
    }

    public func clearSnapshot(scope: String) async throws {
        try await store.clear(scope: scope)
    }
}

public actor InMemorySessionHistoryCacheStore: SessionHistoryCacheStoreProtocol {
    private let store = InMemorySnapshotStore<CachedSessionHistorySnapshot>()

    public init() {}

    public func loadSnapshot(scope: String) async throws -> CachedSessionHistorySnapshot? {
        await store.load(scope: scope)
    }

    public func saveSnapshot(_ snapshot: CachedSessionHistorySnapshot, scope: String) async throws {
        await store.save(snapshot, scope: scope)
    }

    public func clearSnapshot(scope: String) async throws {
        await store.clear(scope: scope)
    }
}
