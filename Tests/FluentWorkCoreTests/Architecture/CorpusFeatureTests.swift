import FactoryKit
import FluentWorkNetworking
import Foundation
import Testing
import TGReduxKitTesting
@testable import FluentWorkCore

@Test func corpusReducerHydratesAndFiltersVisibleItems() throws {
    let blockA = makePhraseBlock(
        id: "b-1",
        intentZH: "表达感谢",
        expressionEN: "Thank you for your patience.",
        anchorUserSaid: "thanks",
        sceneTag: "work",
        functionTag: "gratitude",
        isFavorite: true
    )
    let blockB = makePhraseBlock(
        id: "b-2",
        intentZH: "请求帮助",
        expressionEN: "Could you help me with this?",
        anchorUserSaid: "help",
        sceneTag: "meeting",
        functionTag: "request",
        isFavorite: false
    )
    let store = TestStore(initialState: CorpusState(), reducer: corpusReducer)

    var expected = CorpusState()
    expected.phase = .loading
    store.send(.appear)
    try store.assert(equals: expected)

    expected.items = [blockA, blockB]
    expected.nextCursor = "cursor-1"
    expected.phase = .ready
    store.send(.hydrateFromCache(CachedCorpusSnapshot(items: [blockA, blockB], nextCursor: "cursor-1")))
    try store.assert(equals: expected)

    expected.searchQuery = "thank"
    store.send(.searchQueryChanged("thank"))
    try store.assert(equals: expected)
    #expect(store.state.visibleItems.map(\.id) == ["b-1"])

    expected.favoriteOnly = true
    store.send(.favoriteOnlyChanged(true))
    try store.assert(equals: expected)
    #expect(store.state.visibleItems.map(\.id) == ["b-1"])
}

@Test func corpusReducerAppendsMergedRemotePage() throws {
    let existing = makePhraseBlock(id: "b-1", expressionEN: "One", updatedAt: "2026-08-31T10:00:00Z")
    let updated = makePhraseBlock(id: "b-1", expressionEN: "One updated", updatedAt: "2026-08-31T10:10:00Z")
    let appended = makePhraseBlock(id: "b-2", expressionEN: "Two", updatedAt: "2026-08-31T10:20:00Z")

    let initial = CorpusState(
        phase: .ready,
        items: [existing],
        nextCursor: "cursor-1"
    )
    let store = TestStore(initialState: initial, reducer: corpusReducer)

    var expected = initial
    expected.isRefreshing = true
    store.send(.remoteLoadStarted)
    try store.assert(equals: expected)

    expected.isRefreshing = false
    expected.items = [updated, appended]
    expected.nextCursor = "cursor-2"
    store.send(.remoteLoadSucceeded(ListPhraseBlocksResponse(items: [updated, appended], nextCursor: "cursor-2"), append: true))
    try store.assert(equals: expected)
}

@MainActor
@Test func corpusMiddlewareHydratesCacheThenRefreshesRemote() async throws {
    let cached = makePhraseBlock(id: "cached-1", expressionEN: "Cached")
    let remote = makePhraseBlock(id: "remote-1", expressionEN: "Remote")

    final class StubCorpusClient: CorpusClientProtocol, @unchecked Sendable {
        let listHandler: @Sendable (String?, Int?, Bool) async throws -> ListPhraseBlocksResponse

        init(
            listHandler: @escaping @Sendable (String?, Int?, Bool) async throws -> ListPhraseBlocksResponse
        ) {
            self.listHandler = listHandler
        }

        func listBlocks(
            cursor: String?,
            limit: Int?,
            favoriteOnly: Bool
        ) async throws -> ListPhraseBlocksResponse {
            try await listHandler(cursor, limit, favoriteOnly)
        }

        func batchAccept(
            sourceSessionID: String,
            cards: [RefineCard]
        ) async throws -> BatchAcceptBlocksResponse {
            throw APIError.backend(code: "unexpected", message: "unused")
        }
    }

    actor RecordingCorpusCacheStore: CorpusCacheStoreProtocol {
        private var snapshots: [String: CachedCorpusSnapshot]
        private(set) var lastSavedScope: String?

        init(seed: [String: CachedCorpusSnapshot]) {
            self.snapshots = seed
        }

        func loadSnapshot(scope: String) async throws -> CachedCorpusSnapshot? {
            snapshots[scope]
        }

        func saveSnapshot(_ snapshot: CachedCorpusSnapshot, scope: String) async throws {
            snapshots[scope] = snapshot
            lastSavedScope = scope
        }

        func clearSnapshot(scope: String) async throws {
            snapshots.removeValue(forKey: scope)
        }

        func snapshot(scope: String) -> CachedCorpusSnapshot? {
            snapshots[scope]
        }
    }

    let cache = RecordingCorpusCacheStore(
        seed: [
            "guest-1": CachedCorpusSnapshot(items: [cached], nextCursor: "cursor-cached"),
        ]
    )

    let container = Container()
    container.reset()
    container.corpusCacheStore.register { cache }
    container.corpusClient.register {
        StubCorpusClient { cursor, limit, favoriteOnly in
            #expect(cursor == nil)
            #expect(limit == 50)
            #expect(favoriteOnly == false)
            return ListPhraseBlocksResponse(items: [remote], nextCursor: "cursor-remote")
        }
    }

    var initialState = AppState.initial
    initialState.auth.mode = .guest
    initialState.auth.currentUserID = "guest-1"

    let store = AppStoreFactory.make(container: container, initialState: initialState)
    store.dispatch(AppAction.corpus(.appear))

    try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.corpus.items.map { $0.id } == ["remote-1"]
    }

    #expect(store.state.corpus.phase == CorpusScreenPhase.ready)
    #expect(store.state.corpus.nextCursor == "cursor-remote")
    #expect(await cache.lastSavedScope == "guest-1")
    let refreshedCache = await cache.snapshot(scope: "guest-1")
    #expect(refreshedCache?.items.map { $0.id } == ["remote-1"])
}

@MainActor
@Test func corpusMiddlewareLoadsMoreAndMergesIntoCache() async throws {
    let blockA = makePhraseBlock(id: "b-1", expressionEN: "One")
    let blockB = makePhraseBlock(id: "b-2", expressionEN: "Two")

    final class StubCorpusClient: CorpusClientProtocol, @unchecked Sendable {
        let response: ListPhraseBlocksResponse

        init(response: ListPhraseBlocksResponse) {
            self.response = response
        }

        func listBlocks(
            cursor: String?,
            limit: Int?,
            favoriteOnly: Bool
        ) async throws -> ListPhraseBlocksResponse {
            #expect(cursor == "cursor-1")
            return response
        }

        func batchAccept(
            sourceSessionID: String,
            cards: [RefineCard]
        ) async throws -> BatchAcceptBlocksResponse {
            throw APIError.backend(code: "unexpected", message: "unused")
        }
    }

    let cache = InMemoryCorpusCacheStore()
    try await cache.saveSnapshot(
        CachedCorpusSnapshot(items: [blockA], nextCursor: "cursor-1"),
        scope: "user-42"
    )

    let container = Container()
    container.reset()
    container.corpusCacheStore.register { cache }
    container.corpusClient.register {
        StubCorpusClient(response: ListPhraseBlocksResponse(items: [blockB], nextCursor: nil))
    }

    var initialState = AppState.initial
    initialState.auth.mode = .registered
    initialState.auth.currentUserID = "user-42"
    initialState.corpus = CorpusState(
        phase: .ready,
        items: [blockA],
        nextCursor: "cursor-1"
    )

    let store = AppStoreFactory.make(container: container, initialState: initialState)
    store.dispatch(AppAction.corpus(.loadMoreRequested))

    try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.corpus.items.map { $0.id } == ["b-1", "b-2"]
    }

    let updatedCache = try await cache.loadSnapshot(scope: "user-42")
    #expect(updatedCache?.items.map { $0.id } == ["b-1", "b-2"])
    #expect(updatedCache?.nextCursor == nil)
}

@Test func authPromotionResetsCorpusState() throws {
    let block = makePhraseBlock(id: "b-1")
    let initial = AppState(
        auth: AuthState(mode: .guest, currentUserID: "guest-1", pendingMergeDeviceID: "device-1"),
        corpus: CorpusState(
            phase: .ready,
            items: [block],
            nextCursor: "cursor-1",
            searchQuery: "hello",
            favoriteOnly: true,
            isRefreshing: true,
            lastErrorMessage: "stale"
        )
    )
    let store = TestStore(initialState: initial, reducer: appReducer)

    var expected = initial
    expected.auth.mode = .registered
    expected.auth.currentUserID = "user-42"
    expected.auth.pendingMergeDeviceID = nil
    expected.corpus = CorpusState()
    store.send(.auth(.mergedIntoRegistered(userID: "user-42", deviceID: "device-1")))
    try store.assert(equals: expected)
}

@MainActor
private func waitUntil(
    timeoutNanoseconds: UInt64,
    pollIntervalNanoseconds: UInt64 = 10_000_000,
    condition: @escaping @MainActor () -> Bool
) async throws {
    let start = DispatchTime.now().uptimeNanoseconds
    while !condition() {
        if DispatchTime.now().uptimeNanoseconds - start >= timeoutNanoseconds {
            throw TimeoutError()
        }
        try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
    }
}

private struct TimeoutError: Error {}

private func makePhraseBlock(
    id: String,
    intentZH: String = "表达感谢",
    expressionEN: String = "Thank you.",
    anchorUserSaid: String = "thanks",
    sceneTag: String = "work",
    functionTag: String = "gratitude",
    isFavorite: Bool = false,
    updatedAt: String = "2026-08-31T10:00:00Z"
) -> PhraseBlock {
    PhraseBlock(
        id: id,
        intentZH: intentZH,
        expressionEN: expressionEN,
        anchorUserSaid: anchorUserSaid,
        sceneTag: sceneTag,
        functionTag: functionTag,
        state: "new",
        successStreak: 0,
        nextDueAt: "2026-09-01T10:00:00Z",
        easeFactor: 2.5,
        realUseCount: 0,
        isFavorite: isFavorite,
        pinnedAt: nil,
        sourceSessionID: "session-1",
        createdAt: "2026-08-31T09:00:00Z",
        updatedAt: updatedAt
    )
}
