import FluentWorkNetworking
import TGReduxKit

public enum ReviewScreenPhase: String, Equatable, Sendable {
    case idle
    case loading
    case pending
    case ready
    case failed
}

public struct ReviewState: Equatable, Sendable, State {
    public var sessionID: String?
    public var phase: ReviewScreenPhase
    public var payload: ReviewReadyPayload?
    public var acceptingRefineCardIDs: Set<String>
    public var acceptedRefineCardIDs: Set<String>
    public var acceptErrorMessage: String?
    public var lastErrorMessage: String?

    public init(
        sessionID: String? = nil,
        phase: ReviewScreenPhase = .idle,
        payload: ReviewReadyPayload? = nil,
        acceptingRefineCardIDs: Set<String> = [],
        acceptedRefineCardIDs: Set<String> = [],
        acceptErrorMessage: String? = nil,
        lastErrorMessage: String? = nil
    ) {
        self.sessionID = sessionID
        self.phase = phase
        self.payload = payload
        self.acceptingRefineCardIDs = acceptingRefineCardIDs
        self.acceptedRefineCardIDs = acceptedRefineCardIDs
        self.acceptErrorMessage = acceptErrorMessage
        self.lastErrorMessage = lastErrorMessage
    }

    public var showsSkeleton: Bool {
        payload == nil && (phase == .loading || phase == .pending || phase == .idle)
    }
}

public enum ReviewAction: Equatable, Sendable, Action {
    case appear(sessionID: String?)
    case loadRequested(sessionID: String)
    case applyPoll(ReviewPollResponse)
    case loadFailed(String)
    case acceptRefineCardTapped(cardID: String)
    case acceptRefineCardStarted(cardID: String)
    case acceptRefineCardSucceeded(cardID: String, acceptedCount: Int)
    case acceptRefineCardFailed(cardID: String, message: String)
    case clear
}

public let reviewReducer: Reducer<ReviewState, ReviewAction> = { state, action in
    switch action {
    case let .appear(sessionID):
        let didChangeSession = state.sessionID != sessionID
        state.sessionID = sessionID
        state.lastErrorMessage = nil
        if let sessionID, !sessionID.isEmpty {
            if state.payload == nil || didChangeSession {
                state.phase = .loading
                if didChangeSession {
                    state.payload = nil
                    resetAcceptFlow(on: &state)
                }
            }
        } else {
            state.phase = .idle
            state.payload = nil
            resetAcceptFlow(on: &state)
        }

    case let .loadRequested(sessionID):
        state.sessionID = sessionID
        state.phase = .loading
        state.lastErrorMessage = nil
        resetAcceptFlow(on: &state)

    case let .applyPoll(response):
        state.sessionID = response.sessionID
        switch response.status {
        case .pending:
            state.phase = .pending
            state.lastErrorMessage = nil
        case .ready:
            state.phase = .ready
            state.payload = response.review
            state.lastErrorMessage = nil
            let validIDs = Set(response.review?.refineCards.map(\.id) ?? [])
            state.acceptingRefineCardIDs = state.acceptingRefineCardIDs.intersection(validIDs)
            state.acceptedRefineCardIDs = state.acceptedRefineCardIDs.intersection(validIDs)
        case .failed:
            state.phase = .failed
            state.lastErrorMessage = "回顾生成失败，请稍后重试。"
        }

    case let .loadFailed(message):
        state.phase = .failed
        state.lastErrorMessage = message

    case .acceptRefineCardTapped:
        break

    case let .acceptRefineCardStarted(cardID):
        state.acceptErrorMessage = nil
        state.acceptingRefineCardIDs.insert(cardID)

    case let .acceptRefineCardSucceeded(cardID, _):
        state.acceptErrorMessage = nil
        state.acceptingRefineCardIDs.remove(cardID)
        state.acceptedRefineCardIDs.insert(cardID)

    case let .acceptRefineCardFailed(cardID, message):
        state.acceptingRefineCardIDs.remove(cardID)
        state.acceptErrorMessage = message

    case .clear:
        state = ReviewState()
    }
}

private func resetAcceptFlow(on state: inout ReviewState) {
    state.acceptingRefineCardIDs = []
    state.acceptedRefineCardIDs = []
    state.acceptErrorMessage = nil
}
