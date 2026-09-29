import FactoryKit
import FluentWorkNetworking
import Foundation
import Testing
@testable import FluentWorkCore

/// A fresh, reset `Container` must be a clean slate.
///
/// Four factories are declared `.singleton` — `corpusCacheStore`,
/// `corpusOutboxStore`, `corpusSyncMetadataStore`, `networkMonitor`. Every one
/// of them wraps something stateful, so caching is right in production; the
/// question is *where* FactoryKit puts the cache.
///
/// `Scope.Singleton` resolves against **its own** cache and says so:
///
/// ```swift
/// internal override func resolve<T>(using cache: Cache, ...) -> (T, Bool) {
///     // ignore container's cache in favor of our own
///     return super.resolve(using: self.cache, key: key, ttl: ttl, factory: factory)
/// }
/// ```
///
/// That cache lives on `Scope.singleton`, a **shared** reference — so the value
/// outlives the container that built it and is visible to every other container
/// in the process. A test that registers a fake is therefore registering it
/// process-wide, and a `defer`-based restore cannot help: the tests it leaks
/// into are already running concurrently.
///
/// `Scope.Cached` is the container-scoped equivalent. It does **not** override
/// `resolve`, so it uses the container's own cache — and `Container.reset()`
/// clears that cache. In production everything resolves from `Container.shared`
/// and nothing resets it, so `.cached` behaves exactly like `.singleton`; in
/// tests, each fresh container gets its own.
///
/// The guard asserts the *property* rather than any single factory's type, so
/// it keeps holding as factories are added.
@MainActor
@Test func freshContainersDoNotShareCachedState() async throws {
    let first = Container()
    first.reset()
    let second = Container()
    second.reset()

    // 断言写成**行为**（写进一个容器、另一个读不到），不写成具体类型的身份比较。
    //
    // 原来那版是 `as? JSONCorpusCacheStore !== ...`，它只比「是不是同一个实例」。
    // 这比它看起来更弱：两个新建容器的 JSON 存储是**不同实例却共用同一个磁盘目录**，
    // 写一个另一个照样读得到 —— 而身份比较对这一类共享完全无感。
    // （2026-09-29 变异验出来的：去掉测试进程判别、让存储退回 JSON 版，
    // 行为断言当场红，身份断言仍是绿的。）
    //
    // 行为版同时守住两件事：`.cached` 若退回 `.singleton`（同一实例 ⇒ 写读相通），
    // 以及测试进程里必须解析成内存版（磁盘版共享同一目录 ⇒ 同样相通）。
    try await first.corpusCacheStore().saveSnapshot(
        CachedCorpusSnapshot(items: [], nextCursor: "isolation-probe"),
        scope: "isolation-probe"
    )
    #expect(
        try await second.corpusCacheStore().loadSnapshot(scope: "isolation-probe") == nil,
        "另一个容器读到了这个容器写进去的东西（同一实例，或同一磁盘目录）"
    )

    try await first.corpusOutboxStore().saveItems(
        [
            CorpusOutboxItem(
                id: "isolation-probe",
                blockID: "b-1",
                operation: .favorite,
                payload: CorpusOutboxItem.Payload(isFavorite: true),
                retryCount: 0,
                createdAt: "2026-09-29T00:00:00Z"
            )
        ],
        scope: "isolation-probe"
    )
    #expect(
        try await second.corpusOutboxStore().loadItems(scope: "isolation-probe").isEmpty,
        "另一个容器读到了这个容器写进去的 outbox 条目"
    )

    try await first.corpusSyncMetadataStore().save(
        CorpusSyncMetadata(listCursor: "isolation-probe"),
        scope: "isolation-probe"
    )
    #expect(
        try await second.corpusSyncMetadataStore().load(scope: "isolation-probe") == nil,
        "另一个容器读到了这个容器写进去的同步元数据"
    )

    #expect(
        (first.networkMonitor() as? NWPathNetworkMonitor)
            !== (second.networkMonitor() as? NWPathNetworkMonitor),
        "networkMonitor is shared across containers"
    )
}

/// The same property stated the way the leak reaches a test: a fake registered
/// into one container must be invisible to another.
///
/// This is the symptom `77_` P1-9 recorded — "别的测试拿到你这个假 cache".
@MainActor
@Test func aRegisteredFakeDoesNotReachAnotherContainer() {
    let registering = Container()
    registering.reset()
    let fake = MarkerCacheStore()
    registering.corpusCacheStore.register { fake }

    // The registration is live in the container that made it.
    #expect(registering.corpusCacheStore() as? MarkerCacheStore === fake)

    // A different container registered nothing, so it must not see it.
    let other = Container()
    other.reset()
    #expect(
        other.corpusCacheStore() as? MarkerCacheStore !== fake,
        "a fake registered in one container leaked into another"
    )
}

private actor MarkerCacheStore: CorpusCacheStoreProtocol {
    func loadSnapshot(scope: String) async throws -> CachedCorpusSnapshot? { nil }
    func saveSnapshot(_ snapshot: CachedCorpusSnapshot, scope: String) async throws {}
    func clearSnapshot(scope: String) async throws {}
}
