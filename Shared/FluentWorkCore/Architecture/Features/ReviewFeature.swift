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
    /// 学员丢掉的那些卡（D2「可丢弃」）。
    ///
    /// 存的是**卡的名字**而不是卡本身：产出（`payload`）保持服务端给的那一份不动，
    /// 所以撤回不需要重新拉一次回顾 —— 拉一次是有成本的。
    public var discardedRefineCardIDs: Set<String>
    public var acceptErrorMessage: String?
    public var lastErrorMessage: String?

    public init(
        sessionID: String? = nil,
        phase: ReviewScreenPhase = .idle,
        payload: ReviewReadyPayload? = nil,
        acceptingRefineCardIDs: Set<String> = [],
        acceptedRefineCardIDs: Set<String> = [],
        discardedRefineCardIDs: Set<String> = [],
        acceptErrorMessage: String? = nil,
        lastErrorMessage: String? = nil
    ) {
        self.sessionID = sessionID
        self.phase = phase
        self.payload = payload
        self.acceptingRefineCardIDs = acceptingRefineCardIDs
        self.acceptedRefineCardIDs = acceptedRefineCardIDs
        self.discardedRefineCardIDs = discardedRefineCardIDs
        self.acceptErrorMessage = acceptErrorMessage
        self.lastErrorMessage = lastErrorMessage
    }

    /// 学员现在该看到的那几张卡。
    ///
    /// **视图读这个，不读 `payload.refineCards`。** 抛弃掉的卡仍然留在产出里（那是服务端给的
    /// 一份快照），由这里过滤掉；写成派生访问器而不是在 reducer 里改写产出，是为了让
    /// 「撤回」变成一个没有副作用的动作。
    public var visibleRefineCards: [RefineCard] {
        (payload?.refineCards ?? []).filter { !discardedRefineCardIDs.contains($0.id) }
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
    /// 丢弃一张卡：从学员眼前拿掉，也不许再入库。
    case discardRefineCardTapped(cardID: String)
    /// 撤回上一次丢弃。
    case restoreRefineCardTapped(cardID: String)
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
            // 丢弃也要剪：卡的名字是**内容派生**的，两份不同回顾完全可能撞出同一个名字，
            // 而留着一个已不存在的名字会让**下一次**撞上它的卡凭空消失。
            state.discardedRefineCardIDs = state.discardedRefineCardIDs.intersection(validIDs)
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

    case let .discardRefineCardTapped(cardID):
        // 幂等：重复丢弃同一张卡不该出错，也不该把它从「已撤回」里再翻一次。
        state.discardedRefineCardIDs.insert(cardID)

    case let .restoreRefineCardTapped(cardID):
        state.discardedRefineCardIDs.remove(cardID)

    case .clear:
        state = ReviewState()
    }
}

private func resetAcceptFlow(on state: inout ReviewState) {
    state.acceptingRefineCardIDs = []
    state.acceptedRefineCardIDs = []
    // 丢弃跟着回顾走：卡的名字是内容派生的，所以「上一份回顾里丢过的那张」和「这一份里的
    // 某一张」可能同名。不在这里清掉，学员会看到新回顾凭空少一张卡 —— 而且没有理由可查。
    state.discardedRefineCardIDs = []
    state.acceptErrorMessage = nil
}
