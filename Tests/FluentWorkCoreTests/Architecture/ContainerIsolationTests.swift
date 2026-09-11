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
@Test func freshContainersDoNotShareCachedState() {
    let first = Container()
    first.reset()
    let second = Container()
    second.reset()

    // Two independent containers must build two independent objects. If they
    // resolve to the same instance, something one of them built is visible to
    // the other — which is the leak, whatever leaked.
    #expect(
        (first.corpusCacheStore() as? JSONCorpusCacheStore)
            !== (second.corpusCacheStore() as? JSONCorpusCacheStore),
        "corpusCacheStore is shared across containers"
    )
    #expect(
        (first.corpusOutboxStore() as? JSONCorpusOutboxStore)
            !== (second.corpusOutboxStore() as? JSONCorpusOutboxStore),
        "corpusOutboxStore is shared across containers"
    )
    #expect(
        (first.corpusSyncMetadataStore() as? JSONCorpusSyncMetadataStore)
            !== (second.corpusSyncMetadataStore() as? JSONCorpusSyncMetadataStore),
        "corpusSyncMetadataStore is shared across containers"
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
