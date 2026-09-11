import FluentWorkNetworking
import Foundation
import Testing
import TGReduxKit
@testable import FluentWorkCore

@Suite("Session history list")
struct SessionHistoryFeatureTests {

    private func item(_ id: String) -> SessionHistoryItem {
        SessionHistoryItem(
            sessionID: id,
            sceneType: "voice",
            status: "ended",
            startedAt: Date(timeIntervalSince1970: 1_789_142_524),
            durationSec: 154
        )
    }

    /// Switching tabs must not re-fetch page one and throw away everything
    /// paged in since. The guard is `didRequestInitialLoad`, and nothing else
    /// in the reducer reads it.
    @Test func appearLoadsOnceAndIsIdempotent() {
        var state = SessionHistoryState()
        sessionHistoryReducer(&state, .appear)
        #expect(state.phase == .loading)
        #expect(state.didRequestInitialLoad)

        sessionHistoryReducer(&state, .loadSucceeded(
            SessionHistoryPage(items: [item("a")], nextCursor: "c1", size: 20),
            appending: false
        ))
        sessionHistoryReducer(&state, .appear)

        #expect(state.items.map(\.sessionID) == ["a"], "a second appear must not discard the page already shown")
        #expect(state.nextCursor == "c1")
    }

    /// Appending is what makes a cursor list a list. If the second page
    /// replaced the first, the list would look correct at one page and lose
    /// rows the moment the user scrolled.
    @Test func aSecondPageAppends() {
        var state = SessionHistoryState()
        sessionHistoryReducer(&state, .loadSucceeded(
            SessionHistoryPage(items: [item("a"), item("b")], nextCursor: "c1", size: 20),
            appending: false
        ))
        sessionHistoryReducer(&state, .loadMoreRequested)
        #expect(state.isLoadingMore)

        sessionHistoryReducer(&state, .loadSucceeded(
            SessionHistoryPage(items: [item("c")], nextCursor: nil, size: 20),
            appending: true
        ))

        #expect(state.items.map(\.sessionID) == ["a", "b", "c"])
        #expect(!state.hasMore)
        #expect(!state.isLoadingMore)
    }

    /// "Loaded and there is nothing" is a different thing to say than "here is
    /// your list", and the view says it differently.
    @Test func anEmptyFirstPageIsItsOwnPhase() {
        var state = SessionHistoryState()
        sessionHistoryReducer(&state, .loadSucceeded(
            SessionHistoryPage(items: [], nextCursor: nil, size: 20),
            appending: false
        ))
        #expect(state.phase == .empty)
    }

    /// A failed first page owns the screen; a failed later page does not.
    /// Replacing a list the user is reading with an error page is the wrong
    /// trade for one page they never asked for by name.
    @Test func aFailedFirstPageReplacesTheScreenAndALaterOneDoesNot() {
        var state = SessionHistoryState()
        sessionHistoryReducer(&state, .loadFailed("offline"))
        #expect(state.phase == .failed("offline"))

        var withItems = SessionHistoryState()
        sessionHistoryReducer(&withItems, .loadSucceeded(
            SessionHistoryPage(items: [item("a")], nextCursor: "c1", size: 20),
            appending: false
        ))
        sessionHistoryReducer(&withItems, .loadMoreRequested)
        sessionHistoryReducer(&withItems, .loadFailed("offline"))

        #expect(withItems.items.map(\.sessionID) == ["a"], "the list the user is reading survives")
        #expect(withItems.phase == .ready)
        #expect(!withItems.isLoadingMore, "the spinner must stop even when the page failed")
    }

    /// With no cursor there is nothing more to ask for, and asking would loop.
    @Test func loadMoreIsRefusedWhenThereIsNoCursor() {
        var state = SessionHistoryState()
        sessionHistoryReducer(&state, .loadSucceeded(
            SessionHistoryPage(items: [item("a")], nextCursor: nil, size: 20),
            appending: false
        ))
        sessionHistoryReducer(&state, .loadMoreRequested)
        #expect(!state.isLoadingMore)
    }
}
