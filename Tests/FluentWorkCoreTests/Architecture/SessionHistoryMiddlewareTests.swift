import FactoryKit
import FluentWorkNetworking
import Foundation
import Testing
import TGReduxKit
import os
@testable import FluentWorkCore

private func makeSessionItem(
    _ id: String,
    duration: Int = 154,
    status: String = "ended"
) -> SessionHistoryItem {
    SessionHistoryItem(
        sessionID: id,
        sceneType: "voice",
        status: status,
        startedAt: Date(timeIntervalSince1970: 1_789_142_524),
        durationSec: duration
    )
}

private struct SessionHistoryStubFailure: Error, LocalizedError {
    var errorDescription: String? { "offline" }
}

/// Records every cursor it was asked for, because the interesting assertions in
/// this file are about *which* request was made — page one versus the stored
/// cursor — and a stub that only returns data cannot tell them apart.
private final class StubSessionHistoryClient: SessionHistoryClientProtocol, @unchecked Sendable {
    typealias Responder = @Sendable (String?) throws -> SessionHistoryPage
    typealias DetailResponder = @Sendable (String) throws -> SessionDetail

    private let responder: Responder
    private let detailResponder: DetailResponder
    private let storage = OSAllocatedUnfairLock<[String?]>(initialState: [])
    private let detailStorage = OSAllocatedUnfairLock<[String]>(initialState: [])

    init(
        responder: @escaping Responder,
        detailResponder: @escaping DetailResponder = { sessionID in
            SessionDetail(
                sessionID: sessionID,
                sceneType: "voice",
                status: "ended",
                startedAt: Date(timeIntervalSince1970: 1_789_142_524),
                durationSec: 154
            )
        }
    ) {
        self.responder = responder
        self.detailResponder = detailResponder
    }

    var requestedCursors: [String?] { storage.withLock { $0 } }
    var requestedDetailIDs: [String] { detailStorage.withLock { $0 } }

    func listSessions(cursor: String?, size: Int?) async throws -> SessionHistoryPage {
        storage.withLock { $0.append(cursor) }
        return try responder(cursor)
    }

    func sessionDetail(sessionID: String) async throws -> SessionDetail {
        detailStorage.withLock { $0.append(sessionID) }
        return try detailResponder(sessionID)
    }
}

private func makeDetail(
    _ sessionID: String,
    utterances: [SessionUtterance] = []
) -> SessionDetail {
    SessionDetail(
        sessionID: sessionID,
        sceneType: "voice",
        status: "ended",
        startedAt: Date(timeIntervalSince1970: 1_789_142_524),
        durationSec: 154,
        utterances: utterances
    )
}

@MainActor
private func makeStore(
    client: StubSessionHistoryClient,
    state: SessionHistoryState = SessionHistoryState()
) -> (Store<AppState, AppAction>, StubSessionHistoryClient) {
    let container = Container()
    container.reset()
    container.sessionHistoryClient.register { client }
    var initialState = AppState.initial
    initialState.sessionHistory = state
    return (AppStoreFactory.make(container: container, initialState: initialState), client)
}

/// The list's whole job. If `.appear` did not reach the network the screen
/// would sit on a spinner forever, and nothing above the middleware would say
/// why.
@MainActor
@Test func appearLoadsTheFirstPage() async throws {
    let client = StubSessionHistoryClient { cursor in
        #expect(cursor == nil, "the first page is asked for with no cursor")
        return SessionHistoryPage(
            items: [makeSessionItem("s-1"), makeSessionItem("s-2")],
            nextCursor: "c1",
            size: 20
        )
    }
    let (store, _) = makeStore(client: client)

    store.dispatch(.sessionHistory(.appear))

    try await waitUntil(timeoutNanoseconds: 5_000_000_000) {
        store.state.sessionHistory.phase == .ready
    }
    #expect(store.state.sessionHistory.items.map(\.sessionID) == ["s-1", "s-2"])
    #expect(store.state.sessionHistory.nextCursor == "c1")
    #expect(client.requestedCursors == [nil])
}

/// **This test used to assert the opposite** — that a second appearance did
/// not re-fetch. See `everyAppearanceReloadsTheFirstPage` for why that flipped:
/// this is the room list, and "current" has to mean on every appearance.
///
/// The cost is pinned here rather than left as a footnote: paged-in rows are
/// dropped when the list re-appears. Those rows are the *older* ones, still on
/// the server, and the user can page to them again — which is why the trade was
/// worth taking.
///
/// The waits are load-bearing and not a sleep in disguise: the assertion is on
/// the *number* of requests, so the second appearance has to happen after the
/// first one has actually landed, or the shared task id would cancel it and the
/// test would be measuring the scheduler.
@MainActor
@Test func aLaterAppearanceReloadsPageOneAndDropsPagedInRows() async throws {
    let client = StubSessionHistoryClient { cursor in
        if cursor == nil {
            return SessionHistoryPage(items: [makeSessionItem("s-1")], nextCursor: "c1", size: 20)
        }
        return SessionHistoryPage(items: [makeSessionItem("s-2")], nextCursor: nil, size: 20)
    }
    let (store, _) = makeStore(client: client)

    store.dispatch(.sessionHistory(.appear))
    try await waitUntil(timeoutNanoseconds: 5_000_000_000) {
        store.state.sessionHistory.phase == .ready
    }
    store.dispatch(.sessionHistory(.loadMoreRequested))
    try await waitUntil(timeoutNanoseconds: 5_000_000_000) {
        store.state.sessionHistory.items.count == 2
    }

    // Leaving the room and coming back — the case the user asked to be current.
    store.dispatch(.sessionHistory(.appear))
    try await waitUntil(timeoutNanoseconds: 5_000_000_000) {
        store.state.sessionHistory.appearanceCount == 2
            && store.state.sessionHistory.phase == .ready
    }

    #expect(client.requestedCursors == [nil, "c1", nil])
    #expect(
        store.state.sessionHistory.items.map(\.sessionID) == ["s-1"],
        "page one again, replacing — the paged-in row is the accepted cost of always being current"
    )
}

/// Paging is the difference between a list and a page. The cursor the second
/// request carries comes from state, not from the caller — that is the whole
/// reason `nextCursor` is stored.
@MainActor
@Test func loadMoreCarriesTheStoredCursorAndAppends() async throws {
    let client = StubSessionHistoryClient { cursor in
        #expect(cursor == "c1")
        return SessionHistoryPage(items: [makeSessionItem("s-2")], nextCursor: nil, size: 20)
    }
    let (store, _) = makeStore(
        client: client,
        state: SessionHistoryState(
            phase: .ready,
            items: [makeSessionItem("s-1")],
            nextCursor: "c1"
        )
    )

    store.dispatch(.sessionHistory(.loadMoreRequested))

    try await waitUntil(timeoutNanoseconds: 5_000_000_000) {
        store.state.sessionHistory.items.count == 2
    }
    #expect(store.state.sessionHistory.items.map(\.sessionID) == ["s-1", "s-2"])
    #expect(!store.state.sessionHistory.hasMore)
}

/// A failed first page owns the screen; a failed later page must not. Both
/// halves matter: replacing a list the user is reading with an error page is
/// the wrong trade, and silently swallowing the failure leaves a 加载更多
/// button that stops spinning and looks like it loaded nothing.
@MainActor
@Test func failureTakesOverAnEmptyScreenAndOnlyShowsWhenThereIsAList() async throws {
    let firstPageFails = StubSessionHistoryClient { _ in
        throw SessionHistoryStubFailure()
    }
    let (emptyStore, _) = makeStore(client: firstPageFails)

    emptyStore.dispatch(.sessionHistory(.appear))
    try await waitUntil(timeoutNanoseconds: 5_000_000_000) {
        if case .failed = emptyStore.state.sessionHistory.phase { return true }
        return false
    }
    #expect(emptyStore.state.sessionHistory.errorMessage != nil)

    let laterPageFails = StubSessionHistoryClient { _ in
        throw SessionHistoryStubFailure()
    }
    let (loadedStore, _) = makeStore(
        client: laterPageFails,
        state: SessionHistoryState(
            phase: .ready,
            items: [makeSessionItem("s-1")],
            nextCursor: "c1"
        )
    )

    loadedStore.dispatch(.sessionHistory(.loadMoreRequested))
    try await waitUntil(timeoutNanoseconds: 5_000_000_000) {
        loadedStore.state.sessionHistory.errorMessage != nil
    }

    #expect(loadedStore.state.sessionHistory.items.map(\.sessionID) == ["s-1"])
    #expect(loadedStore.state.sessionHistory.phase == .ready)
    #expect(!loadedStore.state.sessionHistory.isLoadingMore)
}

/// Refresh is page one again, replacing. Paged-in rows are the *older* ones and
/// stay on the server, so dropping them from the screen is correct — but a
/// refresh that asked for the stored cursor instead would silently fetch the
/// wrong page, which is the failure this pins.
@MainActor
@Test func refreshAsksForPageOneAndReplaces() async throws {
    let client = StubSessionHistoryClient { cursor in
        #expect(cursor == nil)
        return SessionHistoryPage(items: [makeSessionItem("s-9")], nextCursor: nil, size: 20)
    }
    let (store, _) = makeStore(
        client: client,
        state: SessionHistoryState(
            phase: .ready,
            items: [makeSessionItem("s-1"), makeSessionItem("s-2")],
            nextCursor: "c1"
        )
    )

    store.dispatch(.sessionHistory(.refreshRequested))

    try await waitUntil(timeoutNanoseconds: 5_000_000_000) {
        store.state.sessionHistory.items.map(\.sessionID) == ["s-9"]
    }
    #expect(client.requestedCursors == [nil])
}

/// The whole point of the detail screen: the transcript comes back and is
/// reachable in state. Everything above this is plumbing.
@MainActor
@Test func detailRequestedLoadsThatSessionsTranscript() async throws {
    let client = StubSessionHistoryClient(
        responder: { _ in
            SessionHistoryPage(items: [], nextCursor: nil, size: 20)
        },
        detailResponder: { sessionID in
            makeDetail(
                sessionID,
                utterances: [
                    SessionUtterance(seq: 1, speaker: "user", text: "How do I say 限流?"),
                    SessionUtterance(seq: 2, speaker: "ai", text: "Rate limiting."),
                ]
            )
        }
    )
    let (store, _) = makeStore(client: client)

    store.dispatch(.sessionHistory(.detailRequested(sessionID: "s-1")))

    try await waitUntil(timeoutNanoseconds: 5_000_000_000) {
        store.state.sessionHistory.detail.phase == .ready
    }
    #expect(client.requestedDetailIDs == ["s-1"])
    #expect(
        store.state.sessionHistory.detail.detail?.utterances.map(\.text)
            == ["How do I say 限流?", "Rate limiting."]
    )
}

/// A response for a session the user has already navigated away from must not
/// land. The task-id cancels the request, so this is the second line of
/// defence — and the reducer is the half that can be tested without racing two
/// real requests.
@MainActor
@Test func aDetailResponseForADifferentSessionIsDropped() async throws {
    let client = StubSessionHistoryClient(
        responder: { _ in SessionHistoryPage(items: [], nextCursor: nil, size: 20) },
        detailResponder: { _ in makeDetail("s-1") }
    )
    let (store, _) = makeStore(
        client: client,
        state: SessionHistoryState(
            phase: .ready,
            items: [makeSessionItem("s-1"), makeSessionItem("s-2")],
            detail: SessionHistoryDetailState(requestedSessionID: "s-2", phase: .loading)
        )
    )

    store.dispatch(.sessionHistory(.detailSucceeded(makeDetail("s-1"))))

    #expect(
        store.state.sessionHistory.detail.detail == nil,
        "the session the user left must not appear under the one they are looking at"
    )
    #expect(store.state.sessionHistory.detail.phase == .loading)
}

@MainActor
@Test func aFailedDetailSurfacesItsMessage() async throws {
    let client = StubSessionHistoryClient(
        responder: { _ in SessionHistoryPage(items: [], nextCursor: nil, size: 20) },
        detailResponder: { _ in throw SessionHistoryStubFailure() }
    )
    let (store, _) = makeStore(client: client)

    store.dispatch(.sessionHistory(.detailRequested(sessionID: "s-1")))

    try await waitUntil(timeoutNanoseconds: 5_000_000_000) {
        if case .failed = store.state.sessionHistory.detail.phase { return true }
        return false
    }
    #expect(store.state.sessionHistory.detail.phase.errorMessage != nil)
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
            throw SessionHistoryTestTimeout()
        }
        try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
    }
}

private struct SessionHistoryTestTimeout: Error {}
