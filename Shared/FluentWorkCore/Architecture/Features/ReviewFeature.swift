import FluentWorkNetworking
import TGReduxKit

public enum ReviewScreenPhase: String, Equatable, Sendable {
    case idle
    case loading
    case pending
    case ready
    case failed
}

/// 学员现在该看到的那一张卡，连同它的**稳定键**。
///
/// 为什么需要这个包装：`RefineCard.id` 是**内容派生**的（`expressionEN-anchorUserSaid`），
/// 所以「编辑」一旦存在，卡自己的 id 就不再是身份 —— 改一个字它就换一个。视图拿它做
/// `ForEach` 的身份或回派的参数，改完第一个字符就再也找不到自己，而这条路上不会报任何错。
public struct VisibleRefineCard: Equatable, Sendable, Identifiable {
    /// **原卡**（服务端给的那张）的 id。稳定：编辑、丢弃都不改它。
    public let key: String
    /// 学员看到的版本（有草稿就是草稿，没有就是原卡）。
    public let card: RefineCard
    /// 这一张被改过（视图据此显示「已修改」）。
    public let isEdited: Bool

    /// `Identifiable` 要的身份就是稳定键。
    public var id: String { key }

    public init(key: String, card: RefineCard, isEdited: Bool) {
        self.key = key
        self.card = card
        self.isEdited = isEdited
    }
}

/// 可以被编辑的字段。
///
/// 逐字段而不是整张卡：整张卡需要一个「编辑中的副本」在视图里存活，而视图一旦持有副本，
/// 状态就有两处，撤回/丢弃要对齐两份 —— 逐字段让 reducer 成为**唯一**合并点。
public enum RefineCardEditField: String, Equatable, Sendable, CaseIterable {
    case intentZH
    case expressionEN
    case anchorUserSaid
    case sceneTag
    case functionTag
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
    /// 改过的卡：**原卡 id** → 改后的版本。
    ///
    /// 键是原卡的 id，不是草稿自己的 id —— 见 `VisibleRefineCard` 的说明。
    public var refineCardDrafts: [String: RefineCard]
    public var acceptErrorMessage: String?
    public var lastErrorMessage: String?

    public init(
        sessionID: String? = nil,
        phase: ReviewScreenPhase = .idle,
        payload: ReviewReadyPayload? = nil,
        acceptingRefineCardIDs: Set<String> = [],
        acceptedRefineCardIDs: Set<String> = [],
        discardedRefineCardIDs: Set<String> = [],
        refineCardDrafts: [String: RefineCard] = [:],
        acceptErrorMessage: String? = nil,
        lastErrorMessage: String? = nil
    ) {
        self.sessionID = sessionID
        self.phase = phase
        self.payload = payload
        self.acceptingRefineCardIDs = acceptingRefineCardIDs
        self.acceptedRefineCardIDs = acceptedRefineCardIDs
        self.discardedRefineCardIDs = discardedRefineCardIDs
        self.refineCardDrafts = refineCardDrafts
        self.acceptErrorMessage = acceptErrorMessage
        self.lastErrorMessage = lastErrorMessage
    }

    /// 学员现在该看到的那几张卡。
    ///
    /// **视图读这个，不读 `payload.refineCards`。** 抛弃掉的卡仍然留在产出里（那是服务端给的
    /// 一份快照），由这里过滤掉；写成派生访问器而不是在 reducer 里改写产出，是为了让
    /// 「撤回」变成一个没有副作用的动作。
    /// **被丢掉的那几张** —— 撤回的入口靠它。
    ///
    /// `visibleRefineCards` 恰好把它们滤掉了，所以没有这一条，「撤回」就成了一条
    /// **没有入口的动作**：reducer 里有 `restoreRefineCardTapped`、判据全绿，
    /// 而屏幕上没有任何东西能把它读出来。
    public var discardedRefineCards: [VisibleRefineCard] {
        (payload?.refineCards ?? []).compactMap { card in
            guard discardedRefineCardIDs.contains(card.id) else { return nil }
            guard let draft = refineCardDrafts[card.id] else {
                return VisibleRefineCard(key: card.id, card: card, isEdited: false)
            }
            return VisibleRefineCard(key: card.id, card: draft, isEdited: true)
        }
    }

    public var visibleRefineCards: [VisibleRefineCard] {
        (payload?.refineCards ?? []).compactMap { card in
            guard !discardedRefineCardIDs.contains(card.id) else { return nil }
            guard let draft = refineCardDrafts[card.id] else {
                return VisibleRefineCard(key: card.id, card: card, isEdited: false)
            }
            // `key` 仍是**原卡**的 id：草稿自己的 id 随内容变，用它做身份就找不回自己。
            return VisibleRefineCard(key: card.id, card: draft, isEdited: true)
        }
    }

    /// 按**稳定键**取一张。入库走这里 —— 它拿到的是学员改过的那一版。
    public func visibleRefineCard(forKey key: String) -> VisibleRefineCard? {
        visibleRefineCards.first { $0.key == key }
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
    /// 改一个字段。`cardID` 是**稳定键**（原卡 id），不是编辑后的 id。
    case refineCardEditChanged(cardID: String, field: RefineCardEditField, value: String)
    /// 放弃编辑，回到服务端给的那一版。
    case refineCardEditReverted(cardID: String)
    // 没有 `.clear`：整屏重置这件事由 `.appear(sessionID: nil)`（→ `.idle`、清 payload、清草稿）
    // 与 `.loadRequested` 覆盖，而它们各自还做对了 `.clear` 做不到的那一半（按内容剪枝）。
    // 那个 action 从前存在，一次都没被派发过。
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
            state.refineCardDrafts = state.refineCardDrafts.filter { validIDs.contains($0.key) }
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

    case let .refineCardEditChanged(cardID, field, value):
        // 两道门都是**必需**的，不是防御性代码：
        //   ① 产出里没有这张卡 ⇒ 收下它会留下一条永远清不掉、也永远看不见的垃圾草稿
        //      （`.ready` 的剪枝按 `validIDs` 走，垃圾名连被清掉的机会都没有）；
        //   ② 已经丢掉了 ⇒ 学员看不见它，却能被一改就复活成可见（草稿优先于原卡）。
        guard let payload = state.payload,
              let original = payload.refineCards.first(where: { $0.id == cardID }),
              !state.discardedRefineCardIDs.contains(cardID)
        else { break }

        var draft = state.refineCardDrafts[cardID] ?? original
        switch field {
        case .intentZH: draft.intentZH = value
        case .expressionEN: draft.expressionEN = value
        case .anchorUserSaid: draft.anchorUserSaid = value
        case .sceneTag: draft.sceneTag = value
        case .functionTag: draft.functionTag = value
        }
        state.refineCardDrafts[cardID] = draft

    case let .refineCardEditReverted(cardID):
        state.refineCardDrafts[cardID] = nil
    }
}

private func resetAcceptFlow(on state: inout ReviewState) {
    state.acceptingRefineCardIDs = []
    state.acceptedRefineCardIDs = []
    // 丢弃跟着回顾走：卡的名字是内容派生的，所以「上一份回顾里丢过的那张」和「这一份里的
    // 某一张」可能同名。不在这里清掉，学员会看到新回顾凭空少一张卡 —— 而且没有理由可查。
    state.discardedRefineCardIDs = []
    // 草稿同理：名字是内容派生的，撞名会让上一份回顾里改过的英文**静默改写**这一份里的卡。
    state.refineCardDrafts = [:]
    state.acceptErrorMessage = nil
}
