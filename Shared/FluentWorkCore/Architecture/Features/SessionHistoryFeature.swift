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

public struct SessionHistoryState: Equatable, Sendable, State {
    public var phase: SessionListPhase
    public var items: [SessionHistoryItem]
    public var nextCursor: String?
    public var isLoadingMore: Bool
    /// Guards against `.appear` firing a second first-page load every time the
    /// tab is switched. Without it, leaving and returning re-fetches page one
    /// and discards anything paged in since.
    public var didRequestInitialLoad: Bool

    public var hasMore: Bool { nextCursor != nil }

    public init(
        phase: SessionListPhase = .idle,
        items: [SessionHistoryItem] = [],
        nextCursor: String? = nil,
        isLoadingMore: Bool = false,
        didRequestInitialLoad: Bool = false
    ) {
        self.phase = phase
        self.items = items
        self.nextCursor = nextCursor
        self.isLoadingMore = isLoadingMore
        self.didRequestInitialLoad = didRequestInitialLoad
    }
}

public enum SessionHistoryAction: Equatable, Sendable, Action {
    case appear
    case refreshRequested
    case loadMoreRequested
    case loadSucceeded(SessionHistoryPage, appending: Bool)
    case loadFailed(String)
}

public let sessionHistoryReducer: Reducer<SessionHistoryState, SessionHistoryAction> = { state, action in
    switch action {
    case .appear:
        guard !state.didRequestInitialLoad else { return }
        state.didRequestInitialLoad = true
        state.phase = .loading

    case .refreshRequested:
        // Keeps whatever is on screen while the new page one arrives — a list
        // that blanks out on pull-to-refresh reads as a failure, not a refresh.
        state.isLoadingMore = false

    case .loadMoreRequested:
        guard state.hasMore, !state.isLoadingMore else { return }
        state.isLoadingMore = true

    case let .loadSucceeded(page, appending):
        state.items = appending ? state.items + page.items : page.items
        state.nextCursor = page.nextCursor
        state.isLoadingMore = false
        state.phase = state.items.isEmpty ? .empty : .ready

    case let .loadFailed(message):
        state.isLoadingMore = false
        // A failed *first* page is the whole screen's problem; a failed
        // subsequent page is not, and replacing a list the user is reading with
        // an error page would be the wrong trade.
        if state.items.isEmpty {
            state.phase = .failed(message)
        }
    }
}
