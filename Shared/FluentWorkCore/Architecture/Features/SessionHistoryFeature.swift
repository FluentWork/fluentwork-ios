import FluentWorkNetworking
import TGReduxKit

/// Where the conversation list is.
///
/// `empty` is its own case rather than `ready` with no items: "you have not
/// practised yet" and "the list is here, it is just blank" are different things
/// to say, and a view that has to infer one from `items.isEmpty` will say the
/// wrong one the first time a filter is added.
public enum SessionListPhase: Equatable, Sendable {
    case idle
    case loading
    case ready
    case empty
    case failed(String)
}

/// Where one past session is. No `empty` case, unlike the list: a session with
/// nothing said in it is still *a* session, and "there is nothing on this
/// screen" is not the same thing to say as "you have no sessions".
public enum SessionDetailPhase: Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed(String)

    public var errorMessage: String? {
        if case let .failed(message) = self { return message }
        return nil
    }
}

public struct SessionHistoryDetailState: Equatable, Sendable, State {
    /// Which session was asked for.
    ///
    /// Set when the request goes out, not when the response arrives, and that
    /// is the point: it is the only thing that can tell a late response for the
    /// session the user just left from one for the session they are looking at.
    /// Both are `SessionDetail`, and `detailSucceeded` has nothing else to
    /// compare against.
    public var requestedSessionID: String?
    public var phase: SessionDetailPhase
    public var detail: SessionDetail?

    public init(
        requestedSessionID: String? = nil,
        phase: SessionDetailPhase = .idle,
        detail: SessionDetail? = nil
    ) {
        self.requestedSessionID = requestedSessionID
        self.phase = phase
        self.detail = detail
    }
}

public struct SessionHistoryState: Equatable, Sendable, State {
    public var phase: SessionListPhase
    public var items: [SessionHistoryItem]
    public var nextCursor: String?
    public var isLoadingMore: Bool
    /// Bumped by every `.appear`, so the middleware can fire the load
    /// unconditionally (see `sessionHistoryMiddleware`) instead of the reducer
    /// having to be the thing that decides.
    ///
    /// This replaced `didRequestInitialLoad`, which loaded **once per process**
    /// and was written when the list was imagined as a tab. It is not a tab: it
    /// is the room list, and the room it is a list of writes a session every
    /// time one runs. A list that shows what was there when the app started is
    /// a list of the past — the user asked for the entry to be current, and
    /// "current" has to mean on every appearance, including coming back from a
    /// session that just ended.
    public var appearanceCount: Int
    /// Message from the most recent failure, cleared by the next request that
    /// starts. Kept even when the failure did not take over the screen: a
    /// "load more" that fails and only stops its spinner is indistinguishable
    /// from one that loaded nothing, and the user's next move — tap it again —
    /// would be a guess.
    public var errorMessage: String?
    /// The pushed detail screen's state, kept here rather than in its own
    /// top-level `AppState` field: it is reached only from this list, and it is
    /// meaningless without it.
    public var detail: SessionHistoryDetailState

    public var hasMore: Bool { nextCursor != nil }

    public init(
        phase: SessionListPhase = .idle,
        items: [SessionHistoryItem] = [],
        nextCursor: String? = nil,
        isLoadingMore: Bool = false,
        appearanceCount: Int = 0,
        errorMessage: String? = nil,
        detail: SessionHistoryDetailState = SessionHistoryDetailState()
    ) {
        self.phase = phase
        self.items = items
        self.nextCursor = nextCursor
        self.isLoadingMore = isLoadingMore
        self.appearanceCount = appearanceCount
        self.errorMessage = errorMessage
        self.detail = detail
    }
}

public enum SessionHistoryAction: Equatable, Sendable, Action {
    case appear
    case refreshRequested
    case loadMoreRequested
    case loadSucceeded(SessionHistoryPage, appending: Bool)
    case loadFailed(String)
    case detailRequested(sessionID: String)
    case detailSucceeded(SessionDetail)
    case detailFailed(String)
}

public let sessionHistoryReducer: Reducer<SessionHistoryState, SessionHistoryAction> = { state, action in
    switch action {
    case .appear:
        // Every appearance, deliberately. See `appearanceCount`.
        state.appearanceCount += 1
        state.phase = .loading
        state.errorMessage = nil

    case .refreshRequested:
        // Keeps whatever is on screen while the new page one arrives — a list
        // that blanks out on pull-to-refresh reads as a failure, not a refresh.
        //
        // With nothing on screen there is nothing to keep, and both ways of
        // getting here need the spinner: a pull on an empty list, and 重试 on a
        // failed first page. The second one is why this is not cosmetic — a
        // retry that leaves the failure page up looks like a dead button.
        state.isLoadingMore = false
        state.errorMessage = nil
        if state.items.isEmpty {
            state.phase = .loading
        }

    case .loadMoreRequested:
        guard state.hasMore, !state.isLoadingMore else { return }
        state.isLoadingMore = true
        state.errorMessage = nil

    case let .loadSucceeded(page, appending):
        state.items = appending ? state.items + page.items : page.items
        state.nextCursor = page.nextCursor
        state.isLoadingMore = false
        state.errorMessage = nil
        state.phase = state.items.isEmpty ? .empty : .ready

    case let .loadFailed(message):
        state.isLoadingMore = false
        state.errorMessage = message
        // A failed *first* page is the whole screen's problem; a failed
        // subsequent page is not, and replacing a list the user is reading with
        // an error page would be the wrong trade.
        if state.items.isEmpty {
            state.phase = .failed(message)
        }

    case let .detailRequested(sessionID):
        state.detail.requestedSessionID = sessionID
        state.detail.phase = .loading
        // Drop whatever was on screen. Leaving the previous session's
        // transcript up while a new one loads would show it under the new
        // row's title, which is the one way this screen can lie.
        state.detail.detail = nil

    case let .detailSucceeded(detail):
        // A response for a session the user has already navigated away from.
        // The task-id cancels the request itself, so this is the second line of
        // defence — and the one that still holds if the task and the dispatch
        // ever get separated.
        guard detail.sessionID == state.detail.requestedSessionID else { return }
        state.detail.detail = detail
        state.detail.phase = .ready

    case let .detailFailed(message):
        state.detail.phase = .failed(message)
    }
}
