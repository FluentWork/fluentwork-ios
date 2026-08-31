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
    public var lastErrorMessage: String?

    public init(
        sessionID: String? = nil,
        phase: ReviewScreenPhase = .idle,
        payload: ReviewReadyPayload? = nil,
        lastErrorMessage: String? = nil
    ) {
        self.sessionID = sessionID
        self.phase = phase
        self.payload = payload
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
    case clear
}

public let reviewReducer: Reducer<ReviewState, ReviewAction> = { state, action in
    switch action {
    case let .appear(sessionID):
        state.sessionID = sessionID
        state.lastErrorMessage = nil
        if let sessionID, !sessionID.isEmpty {
            if state.payload == nil || state.sessionID != sessionID {
                state.phase = .loading
            }
        } else {
            state.phase = .idle
            state.payload = nil
        }

    case let .loadRequested(sessionID):
        state.sessionID = sessionID
        state.phase = .loading
        state.lastErrorMessage = nil

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
        case .failed:
            state.phase = .failed
            state.lastErrorMessage = "回顾生成失败，请稍后重试。"
        }

    case let .loadFailed(message):
        state.phase = .failed
        state.lastErrorMessage = message

    case .clear:
        state = ReviewState()
    }
}
