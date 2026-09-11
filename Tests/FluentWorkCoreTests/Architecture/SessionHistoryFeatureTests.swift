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

    /// **This test used to assert the opposite**, and the flip is the fix.
    ///
    /// It pinned "`.appear` loads once per process" — a `didRequestInitialLoad`
    /// guard written when this list was imagined as a tab. It is not a tab: it
    /// is the **room list**, and the room writes a session every time one runs.
    /// A list frozen at process start is a list of the past, and the user asked
    /// for the entry to be current — including coming back from a session that
    /// just ended, which is the common case.
    ///
    /// The cost is real and accepted: returning to the list re-fetches page one
    /// and drops rows that were paged in. Those rows are older ones, still on
    /// the server, and the user can page to them again.
    @Test func everyAppearanceReloadsTheFirstPage() {
        var state = SessionHistoryState()
        sessionHistoryReducer(&state, .appear)
        #expect(state.phase == .loading)
        #expect(state.appearanceCount == 1)

        sessionHistoryReducer(&state, .loadSucceeded(
            SessionHistoryPage(items: [item("a")], nextCursor: "c1", size: 20),
            appending: false
        ))
        sessionHistoryReducer(&state, .appear)

        #expect(state.appearanceCount == 2)
        #expect(state.phase == .loading, "the fresh page one is on its way; showing the old one would be the stale list again")
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
        #expect(
            withItems.errorMessage == "offline",
            "a failure that did not take the screen still has to be sayable"
        )
    }

    /// A retry after a failed first page, and a pull-to-refresh on an empty
    /// list, are the same action. If the reducer left the phase on `.failed`,
    /// the retry button would look like it did nothing at all until the
    /// response came back, which is the same as being broken.
    @Test func refreshShowsTheSpinnerWhenThereIsNothingToKeep() {
        var failed = SessionHistoryState()
        sessionHistoryReducer(&failed, .loadFailed("offline"))

        sessionHistoryReducer(&failed, .refreshRequested)
        #expect(failed.phase == .loading)
        #expect(failed.errorMessage == nil, "the old failure must not outlive the retry")

        // ...but a list the user is reading keeps rendering while the new page
        // one is in flight — blanking out on a pull-to-refresh reads as a
        // failure, not a refresh.
        var loaded = SessionHistoryState()
        sessionHistoryReducer(&loaded, .loadSucceeded(
            SessionHistoryPage(items: [item("a")], nextCursor: "c1", size: 20),
            appending: false
        ))
        sessionHistoryReducer(&loaded, .refreshRequested)
        #expect(loaded.phase == .ready)
        #expect(loaded.items.map(\.sessionID) == ["a"])
    }

    /// Opening a second row must not leave the first one's transcript on
    /// screen. It would render under the new row's title, which is the one way
    /// this screen can tell a lie rather than just look unfinished.
    @Test func openingAnotherSessionClearsTheOneOnScreen() {
        var state = SessionHistoryState()
        sessionHistoryReducer(&state, .detailRequested(sessionID: "a"))
        sessionHistoryReducer(&state, .detailSucceeded(
            SessionDetail(
                sessionID: "a",
                sceneType: "voice",
                status: "ended",
                startedAt: Date(timeIntervalSince1970: 1_789_142_524),
                durationSec: 154,
                utterances: [SessionUtterance(seq: 1, speaker: "user", text: "hello")]
            )
        ))
        #expect(state.detail.phase == .ready)

        sessionHistoryReducer(&state, .detailRequested(sessionID: "b"))

        #expect(state.detail.detail == nil, "the previous session's transcript must not linger")
        #expect(state.detail.phase == .loading)
        #expect(state.detail.requestedSessionID == "b")
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
