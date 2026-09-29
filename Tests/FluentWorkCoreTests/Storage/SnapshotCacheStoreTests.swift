import FluentWorkNetworking
import Foundation
import Testing

@testable import FluentWorkCore

/// 快照缓存机制层的判据。
///
/// 三个域（语料库 / 历史 / 每日一读）共用这一份机制，所以这里测的是机制，
/// 各域自己的语义（缓存旧了怎么显示、失败要不要清空）在各自的中间件判据里测。
@Suite struct SnapshotCacheStoreTests {

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fw-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeSnapshot(_ ids: [String], nextCursor: String?) -> CachedSessionHistorySnapshot {
        CachedSessionHistorySnapshot(
            items: ids.map {
                SessionHistoryItem(
                    sessionID: $0,
                    sceneType: "voice",
                    status: "ended",
                    startedAt: Date(timeIntervalSince1970: 1_789_142_524),
                    durationSec: 154
                )
            },
            nextCursor: nextCursor
        )
    }

    @Test func theJSONStoreRoundTripsAndForgets() async throws {
        let directory = try makeTemporaryDirectory()
        let store = JSONSnapshotStore<CachedSessionHistorySnapshot>(
            filePrefix: "probe",
            directoryURL: directory
        )
        let snapshot = makeSnapshot(["s-1", "s-2"], nextCursor: "c-9")

        #expect(try await store.load(scope: "user-1") == nil)

        try await store.save(snapshot, scope: "user-1")
        #expect(try await store.load(scope: "user-1") == snapshot)

        try await store.clear(scope: "user-1")
        #expect(try await store.load(scope: "user-1") == nil)

        // 清一个不存在的 scope 不该抛：它已经达到目的了。
        try await store.clear(scope: "user-1")
    }

    @Test func theJSONStoreWritesOneFilePerScope() async throws {
        let directory = try makeTemporaryDirectory()
        let store = JSONSnapshotStore<CachedSessionHistorySnapshot>(
            filePrefix: "probe",
            directoryURL: directory
        )

        try await store.save(makeSnapshot(["a"], nextCursor: nil), scope: "user-1")
        try await store.save(makeSnapshot(["b"], nextCursor: nil), scope: "user-2")

        #expect(try await store.load(scope: "user-1")?.items.map(\.sessionID) == ["a"])
        #expect(try await store.load(scope: "user-2")?.items.map(\.sessionID) == ["b"])
    }

    /// scope 来自 `auth.currentUserID`，它是外部输入。若不做净化，
    /// 一个形如 `../other` 的 scope 就能把快照写到目录外面去。
    @Test func aScopeCannotEscapeTheCacheDirectory() async throws {
        let directory = try makeTemporaryDirectory()
        let store = JSONSnapshotStore<CachedSessionHistorySnapshot>(
            filePrefix: "probe",
            directoryURL: directory
        )

        try await store.save(makeSnapshot(["escaped"], nextCursor: nil), scope: "../../outside")

        let entries = try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        )
        #expect(entries.count == 1, "配出了多个文件，说明 scope 被当成了路径：\(entries)")
        #expect(entries.allSatisfy { $0.hasPrefix("probe-") && $0.hasSuffix(".json") })

        let parentEntries = try FileManager.default.contentsOfDirectory(
            atPath: directory.deletingLastPathComponent().path
        )
        #expect(
            !parentEntries.contains { $0.hasPrefix("probe-") },
            "快照跑到缓存目录外面去了：\(parentEntries)"
        )

        // 净化后仍要能读回来：它只是把分隔符换掉，不是丢弃。
        #expect(try await store.load(scope: "../../outside")?.items.map(\.sessionID) == ["escaped"])
    }

    @Test func theInMemoryStoreIsolatesScopes() async throws {
        let store = InMemorySnapshotStore<CachedDailyReadSnapshot>()

        #expect(await store.load(scope: "user-1") == nil)

        let snapshot = CachedDailyReadSnapshot(genDate: "2026-09-01", dailyRead: makeFixtureDailyRead())
        await store.save(snapshot, scope: "user-1")

        #expect(await store.load(scope: "user-1") == snapshot)
        #expect(await store.load(scope: "user-2") == nil)

        await store.clear(scope: "user-1")
        #expect(await store.load(scope: "user-1") == nil)
    }
}

/// `private` 而不是 internal：`DailyReadMiddlewareTests` 与
/// `DailyReadAudioPlayerTests` 各自已经有一个同名 helper，全仓再放一个
/// internal 的重载会让 `makeDailyRead()` 在那些文件里变成歧义调用。
private func makeFixtureDailyRead() -> DailyRead {
    DailyRead(
        id: "dr-001",
        title: "Daily Read Sample",
        body: "Today's short passage for practice.",
        audioURL: "https://example.com/audio.mp3",
        generator: "volc-ark",
        usedBlockIDs: [],
        sourceRefs: [:]
    )
}
