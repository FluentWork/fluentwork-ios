import FluentWorkNetworking
import Foundation

/// 今日一读的**只读展示**缓存：弱网下进屏不留白页（稿子 §07 场景 06）。
///
/// 带上 `genDate` 一起缓存，是这份快照最要紧的一处：进屏时若只能拿到缓存，
/// 屏幕上显示的日期就是**这份内容自己的日期**，而不是「今天」。
/// 跨了一天又在弱网里，用户看到的是「29 日的每日一读」并被告知它属于 29 日 ——
/// 而不是把昨天的内容当成今天的端上来。缓存可以旧，但不能说谎。
///
/// 与历史同理，它不参与写回合并：每日一读由服务端生成，客户端只读。
public struct CachedDailyReadSnapshot: Codable, Equatable, Sendable {
    public var genDate: String
    public var dailyRead: DailyRead

    public init(genDate: String, dailyRead: DailyRead) {
        self.genDate = genDate
        self.dailyRead = dailyRead
    }
}

public protocol DailyReadCacheStoreProtocol: Sendable {
    func loadSnapshot(scope: String) async throws -> CachedDailyReadSnapshot?
    func saveSnapshot(_ snapshot: CachedDailyReadSnapshot, scope: String) async throws
    func clearSnapshot(scope: String) async throws
}

public actor JSONDailyReadCacheStore: DailyReadCacheStoreProtocol {
    private let store: JSONSnapshotStore<CachedDailyReadSnapshot>

    public init(directoryURL: URL? = nil) {
        store = JSONSnapshotStore(filePrefix: "daily-read", directoryURL: directoryURL)
    }

    public func loadSnapshot(scope: String) async throws -> CachedDailyReadSnapshot? {
        try await store.load(scope: scope)
    }

    public func saveSnapshot(_ snapshot: CachedDailyReadSnapshot, scope: String) async throws {
        try await store.save(snapshot, scope: scope)
    }

    public func clearSnapshot(scope: String) async throws {
        try await store.clear(scope: scope)
    }
}

public actor InMemoryDailyReadCacheStore: DailyReadCacheStoreProtocol {
    private let store = InMemorySnapshotStore<CachedDailyReadSnapshot>()

    public init() {}

    public func loadSnapshot(scope: String) async throws -> CachedDailyReadSnapshot? {
        await store.load(scope: scope)
    }

    public func saveSnapshot(_ snapshot: CachedDailyReadSnapshot, scope: String) async throws {
        await store.save(snapshot, scope: scope)
    }

    public func clearSnapshot(scope: String) async throws {
        await store.clear(scope: scope)
    }
}
