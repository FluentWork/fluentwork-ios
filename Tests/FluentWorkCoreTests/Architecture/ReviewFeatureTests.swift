import FactoryKit
import FluentWorkNetworking
import Foundation
import Testing
import TGReduxKitTesting
@testable import FluentWorkCore

@Test func reviewReducerTransitionsThroughPendingReadyAndFailed() throws {
    let store = TestStore(initialState: AppState.initial, reducer: appReducer)

    var expected = AppState.initial
    expected.review.sessionID = "s-1"
    expected.review.phase = .loading
    store.send(.review(.appear(sessionID: "s-1")))
    try store.assert(equals: expected)

    expected.review.phase = .pending
    store.send(.review(.applyPoll(ReviewPollResponse(sessionID: "s-1", status: .pending))))
    try store.assert(equals: expected)

    let payload = try makeReadyPayload()

    expected.review.phase = .ready
    expected.review.payload = payload
    store.send(.review(.applyPoll(ReviewPollResponse(sessionID: "s-1", status: .ready, review: payload))))
    try store.assert(equals: expected)

    expected.review.phase = .failed
    expected.review.lastErrorMessage = "回顾生成失败，请稍后重试。"
    store.send(.review(.applyPoll(ReviewPollResponse(sessionID: "s-1", status: .failed))))
    try store.assert(equals: expected)
}

@Test func reviewReducerTracksRefineCardAcceptLifecycle() throws {
    let payload = try makeReadyPayload()
    let cardID = try #require(payload.refineCards.first?.id)
    let store = TestStore(initialState: AppState.initial, reducer: appReducer)

    var expected = AppState.initial
    expected.review.sessionID = "s-1"
    expected.review.phase = .ready
    expected.review.payload = payload
    store.send(.review(.applyPoll(ReviewPollResponse(sessionID: "s-1", status: .ready, review: payload))))
    try store.assert(equals: expected)

    expected.review.acceptingRefineCardIDs = [cardID]
    store.send(.review(.acceptRefineCardStarted(cardID: cardID)))
    try store.assert(equals: expected)

    expected.review.acceptingRefineCardIDs = []
    expected.review.acceptedRefineCardIDs = [cardID]
    store.send(.review(.acceptRefineCardSucceeded(cardID: cardID, acceptedCount: 1)))
    try store.assert(equals: expected)

    expected.review.acceptErrorMessage = "accept failed"
    store.send(.review(.acceptRefineCardFailed(cardID: cardID, message: "accept failed")))
    try store.assert(equals: expected)
}

@MainActor
@Test func reviewMiddlewareLoadsFullReviewPayload() async throws {
    let payload = try makeReadyPayload()

    final class StubSpeechSessionClient: SpeechSessionClientProtocol, @unchecked Sendable {
        let poll: ReviewPollResponse

        init(poll: ReviewPollResponse) {
            self.poll = poll
        }

        func startSession(continueFromSessionID: String?, creation: PracticeCreation?) async throws {}
        func activeSessionID() async -> String? { nil }
        func sendSpeechBoundary(started: Bool, turnID: String?, text: String?) async throws {}
        func sendTurnAbort(turnID: String, outcome: TurnOutcome) async throws {}
        func sendAudioPCM(_ data: Data) async throws {}
        func sendInterrupt() async {}
        func sendRescueRequest() async {}
        func transportEvents() -> AsyncStream<SocketTransportEvent> {
            AsyncStream { continuation in
                continuation.finish()
            }
        }
        func pollReview(sessionID: String) async throws -> ReviewPollResponse { poll }
        func sendDegradedTextMessage(_ text: String) async throws -> PostMessageResponse {
            PostMessageResponse(sessionID: sessionIDFallback, reply: "", channel: "text", generator: "stub")
        }
        func endSession() async {}
        func closeTransport() async {}

        private let sessionIDFallback = "s-1"
    }

    let container = Container()
    container.speechSessionClient.register {
        StubSpeechSessionClient(
            poll: ReviewPollResponse(sessionID: "s-1", status: .ready, review: payload)
        )
    }

    let store = AppStoreFactory.make(container: container)
    store.dispatch(.review(.appear(sessionID: "s-1")))
    try await waitUntil(timeoutNanoseconds: 5_000_000_000) {
        store.state.review.phase == .ready
    }

    #expect(store.state.review.phase == .ready)
    #expect(store.state.review.payload?.generator == "ark-review-refine-v1")
    #expect(store.state.review.payload?.transcript.count == 2)
    #expect(store.state.review.payload?.refineCards.count == 1)
}

@MainActor
@Test func reviewMiddlewarePollsUntilReadyAfterPending() async throws {
    let payload = try makeReadyPayload()

    actor PollTurnBox {
        private var calls = 0

        func next() -> Int {
            calls += 1
            return calls
        }
    }

    final class PendingThenReadySpeechClient: SpeechSessionClientProtocol, @unchecked Sendable {
        let readyPayload: ReviewReadyPayload
        private let box = PollTurnBox()

        init(readyPayload: ReviewReadyPayload) {
            self.readyPayload = readyPayload
        }

        func startSession(continueFromSessionID: String?, creation: PracticeCreation?) async throws {}
        func activeSessionID() async -> String? { nil }
        func sendSpeechBoundary(started: Bool, turnID: String?, text: String?) async throws {}
        func sendTurnAbort(turnID: String, outcome: TurnOutcome) async throws {}
        func sendAudioPCM(_ data: Data) async throws {}
        func sendInterrupt() async {}
        func sendRescueRequest() async {}
        func transportEvents() -> AsyncStream<SocketTransportEvent> {
            AsyncStream { continuation in
                continuation.finish()
            }
        }
        func pollReview(sessionID: String) async throws -> ReviewPollResponse {
            let call = await box.next()
            if call < 3 {
                return ReviewPollResponse(sessionID: sessionID, status: .pending, review: nil)
            }
            return ReviewPollResponse(sessionID: sessionID, status: .ready, review: readyPayload)
        }
        func sendDegradedTextMessage(_ text: String) async throws -> PostMessageResponse {
            PostMessageResponse(sessionID: "s-1", reply: "", channel: "text", generator: "stub")
        }
        func endSession() async {}
        func closeTransport() async {}
    }

    let container = Container()
    container.speechSessionClient.register {
        PendingThenReadySpeechClient(readyPayload: payload)
    }

    let store = AppStoreFactory.make(container: container)
    store.dispatch(.review(.appear(sessionID: "s-1")))
    try await waitUntil(timeoutNanoseconds: 8_000_000_000) {
        store.state.review.phase == .ready
    }

    #expect(store.state.review.phase == .ready)
    #expect(store.state.review.payload?.refineCards.count == 1)
}

@MainActor
@Test func reviewMiddlewareAcceptsRefineCardIntoCorpus() async throws {
    let payload = try makeReadyPayload()
    let card = try #require(payload.refineCards.first)

    final class StubCorpusClient: CorpusClientProtocol, @unchecked Sendable {
        let handler: @Sendable (String, [RefineCard]) async throws -> BatchAcceptBlocksResponse

        init(
            handler: @escaping @Sendable (String, [RefineCard]) async throws -> BatchAcceptBlocksResponse
        ) {
            self.handler = handler
        }

        func listBlocks(
            cursor: String?,
            updatedAfter: String?,
            limit: Int?,
            favoriteOnly: Bool
        ) async throws -> ListPhraseBlocksResponse {
            throw APIError.backend(code: "unexpected", message: "unused")
        }

        func setFavorite(
            blockID: String,
            isFavorite: Bool,
            pinned: Bool
        ) async throws -> PhraseBlock {
            throw APIError.backend(code: "unexpected", message: "unused")
        }

        func deleteBlock(blockID: String) async throws {
            throw APIError.backend(code: "unexpected", message: "unused")
        }

        func batchAccept(
            sourceSessionID: String,
            cards: [RefineCard]
        ) async throws -> BatchAcceptBlocksResponse {
            try await handler(sourceSessionID, cards)
        }
    }

    let container = Container()
    container.corpusClient.register {
        StubCorpusClient { sourceSessionID, cards in
            #expect(sourceSessionID == "s-1")
            #expect(cards.map(\.id) == [card.id])
            return try makeBatchAcceptResponse(acceptedCount: 1)
        }
    }

    var initialState = AppState.initial
    initialState.review.sessionID = "s-1"
    initialState.review.phase = .ready
    initialState.review.payload = payload

    let store = AppStoreFactory.make(container: container, initialState: initialState)
    store.dispatch(.review(.acceptRefineCardTapped(cardID: card.id)))

    try await waitUntil(timeoutNanoseconds: 5_000_000_000) {
        store.state.review.acceptedRefineCardIDs.contains(card.id)
    }

    #expect(store.state.review.acceptingRefineCardIDs.isEmpty)
    #expect(store.state.review.acceptedRefineCardIDs == [card.id])
    #expect(store.state.review.acceptErrorMessage == nil)
}

@MainActor
@Test func reviewMiddlewareSurfacesCorpusAcceptFailure() async throws {
    let payload = try makeReadyPayload()
    let card = try #require(payload.refineCards.first)

    final class FailingCorpusClient: CorpusClientProtocol, @unchecked Sendable {
        func listBlocks(
            cursor: String?,
            updatedAfter: String?,
            limit: Int?,
            favoriteOnly: Bool
        ) async throws -> ListPhraseBlocksResponse {
            throw APIError.backend(code: "unexpected", message: "unused")
        }

        func setFavorite(
            blockID: String,
            isFavorite: Bool,
            pinned: Bool
        ) async throws -> PhraseBlock {
            throw APIError.backend(code: "unexpected", message: "unused")
        }

        func deleteBlock(blockID: String) async throws {
            throw APIError.backend(code: "unexpected", message: "unused")
        }

        func batchAccept(
            sourceSessionID: String,
            cards: [RefineCard]
        ) async throws -> BatchAcceptBlocksResponse {
            throw APIError.backend(code: "forbidden", message: "accept denied")
        }
    }

    let container = Container()
    container.corpusClient.register {
        FailingCorpusClient()
    }

    var initialState = AppState.initial
    initialState.review.sessionID = "s-1"
    initialState.review.phase = .ready
    initialState.review.payload = payload

    let store = AppStoreFactory.make(container: container, initialState: initialState)
    store.dispatch(.review(.acceptRefineCardTapped(cardID: card.id)))

    try await waitUntil(timeoutNanoseconds: 5_000_000_000) {
        store.state.review.acceptErrorMessage == "accept denied"
    }

    #expect(store.state.review.acceptingRefineCardIDs.isEmpty)
    #expect(store.state.review.acceptedRefineCardIDs.isEmpty)
    #expect(store.state.review.acceptErrorMessage == "accept denied")
}

// MARK: - D2 · 可丢弃（PRD §7.2 D2）

/// 丢弃一张卡：它从学员眼前消失，也不会被送进语料库。
///
/// **原始产出不动**（`payload.refineCards` 仍是服务端给的那一份）：丢弃是学员的取舍，
/// 不是对产出的改写 —— 否则撤回就只能重新拉一次回顾，而回顾生成是有成本的。
@Test func discardingARefineCardHidesItFromTheLearner() throws {
    let payload = try makeReadyPayload()
    let cardID = try #require(payload.refineCards.first?.id)
    let store = TestStore(initialState: AppState.initial, reducer: appReducer)

    store.send(.review(.applyPoll(ReviewPollResponse(sessionID: "s-1", status: .ready, review: payload))))
    #expect(store.state.review.visibleRefineCards.count == 1)

    store.send(.review(.discardRefineCardTapped(cardID: cardID)))

    #expect(
        store.state.review.discardedRefineCardIDs == [cardID],
        "丢弃没有落到状态上"
    )
    #expect(
        store.state.review.visibleRefineCards.isEmpty,
        "丢弃之后这张卡还在视图里：\(store.state.review.visibleRefineCards.map(\.id))"
    )
    #expect(
        store.state.review.payload?.refineCards.count == 1,
        "丢弃改写了服务端给的产出 —— 撤回就只剩「重新拉一次回顾」这条路"
    )
}

/// 丢弃要能撤回。
///
/// 没有撤回的丢弃是一条**单行道**：点错一次就永久少一张卡，而回顾页没有别的入口能找回来
/// （产出是服务端给的一份快照）。
@Test func aDiscardedCardCanBeBroughtBack() throws {
    let payload = try makeReadyPayload()
    let cardID = try #require(payload.refineCards.first?.id)
    let store = TestStore(initialState: AppState.initial, reducer: appReducer)
    store.send(.review(.applyPoll(ReviewPollResponse(sessionID: "s-1", status: .ready, review: payload))))

    store.send(.review(.discardRefineCardTapped(cardID: cardID)))
    #expect(store.state.review.visibleRefineCards.isEmpty)

    store.send(.review(.restoreRefineCardTapped(cardID: cardID)))
    #expect(store.state.review.discardedRefineCardIDs.isEmpty, "撤回没有把丢弃拿掉")
    #expect(store.state.review.visibleRefineCards.map(\.id) == [cardID], "撤回之后卡没回来")
}

/// 丢弃**不许跨回顾存活**。
///
/// 卡的 id 是**内容派生**的（`expressionEN-anchorUserSaid`），所以两个会话完全可能产出同一个
/// id。丢弃集合若跨会话存活，B 会话里那张同 id 的卡会被 A 会话的丢弃**静默藏起来** ——
/// 学员只看到「少了一张」，没有任何东西告诉他为什么。
///
/// 同一条理由要求新一版产出也剪枝：服务端重出一份回顾时，卡可能已经不是同一批了。
@Test func discardsDoNotOutliveTheirReview() throws {
    let payload = try makeReadyPayload()
    let cardID = try #require(payload.refineCards.first?.id)

    let store = TestStore(initialState: AppState.initial, reducer: appReducer)
    store.send(.review(.applyPoll(ReviewPollResponse(sessionID: "s-1", status: .ready, review: payload))))
    store.send(.review(.discardRefineCardTapped(cardID: cardID)))
    #expect(store.state.review.discardedRefineCardIDs == [cardID])

    store.send(.review(.loadRequested(sessionID: "s-2")))
    #expect(
        store.state.review.discardedRefineCardIDs.isEmpty,
        "丢弃跟着学员跨了会话 —— 新会话里同 id 的卡会被静默藏起来"
    )

    // 新一版产出里没有那张卡：集合里剩下的名字要剪掉。
    var seeded = AppState.initial
    seeded.review.sessionID = "s-1"
    seeded.review.discardedRefineCardIDs = ["已经不存在的卡"]
    let second = TestStore(initialState: seeded, reducer: appReducer)
    second.send(.review(.applyPoll(ReviewPollResponse(sessionID: "s-1", status: .ready, review: payload))))
    #expect(
        second.state.review.discardedRefineCardIDs.isEmpty,
        "上一轮的丢弃粘在了新产出上：\(second.state.review.discardedRefineCardIDs)"
    )
}

/// 丢弃的卡**连请求都不许发**。
///
/// 判据落在中间件而不是 reducer：接收入口那道 guard 若仍按 `payload.refineCards` 查卡，
/// 被丢弃的卡照样能入库 —— 学员会看到它一边从眼前消失、一边出现在语料库里。
@MainActor
@Test func aDiscardedCardIsNeverSentToTheCorpus() async throws {
    let payload = try makeReadyPayload()
    let card = try #require(payload.refineCards.first)
    let calls = AcceptCallCounter()

    let container = Container()
    container.corpusClient.register {
        RecordingAcceptCorpusClient { _, _ in
            calls.bump()
            return try makeBatchAcceptResponse(acceptedCount: 1)
        }
    }

    var initialState = AppState.initial
    initialState.review.sessionID = "s-1"
    initialState.review.phase = .ready
    initialState.review.payload = payload

    let store = AppStoreFactory.make(container: container, initialState: initialState)
    store.dispatch(.review(.discardRefineCardTapped(cardID: card.id)))
    store.dispatch(.review(.acceptRefineCardTapped(cardID: card.id)))

    // 给那条本该被 guard 挡住的 `.task` 足够的时间出错。
    try await Task.sleep(for: .milliseconds(300))

    #expect(calls.count == 0, "丢弃的卡还是被送进了语料库")
    #expect(store.state.review.acceptingRefineCardIDs.isEmpty, "丢弃的卡进了「入库中」")
    #expect(store.state.review.acceptedRefineCardIDs.isEmpty)
}

// MARK: - D2 · 可编辑（PRD §7.2 D2）

/// 编辑之后，学员看到的就是改过的那一版。
@Test func editingACardChangesWhatTheLearnerSees() throws {
    let payload = try makeReadyPayload()
    let card = try #require(payload.refineCards.first)
    let store = TestStore(initialState: AppState.initial, reducer: appReducer)
    store.send(.review(.applyPoll(ReviewPollResponse(sessionID: "s-1", status: .ready, review: payload))))

    store.send(.review(.refineCardEditChanged(
        cardID: card.id,
        field: .expressionEN,
        value: "I'll circle back with the team tomorrow."
    )))

    let shown = try #require(store.state.review.visibleRefineCards.first)
    #expect(shown.card.expressionEN == "I'll circle back with the team tomorrow.")
    #expect(shown.isEdited, "改过之后没有标记 —— 学员看不出这一张是自己动过的")
    #expect(shown.card.intentZH == card.intentZH, "只改了英文，中文意图被顺手改掉了")
    #expect(store.state.review.payload?.refineCards.first?.expressionEN == card.expressionEN,
            "编辑改写了服务端给的产出")
}

/// **稳定键在编辑之后必须还是原来那个。**
///
/// 这是这一笔最容易踩空的地方：`RefineCard.id` 是**内容派生**的
/// （`expressionEN-anchorUserSaid`），所以改一个字它就换一个。视图拿「编辑后的卡自己的 id」
/// 去回派（入库、再编辑、撤回），改完第一个字符就再也找不到自己了 —— 而这条路上没有任何
/// 东西会报错，学员只会发现按钮失灵。
@Test func theStableKeySurvivesAnEdit() throws {
    let payload = try makeReadyPayload()
    let card = try #require(payload.refineCards.first)
    let store = TestStore(initialState: AppState.initial, reducer: appReducer)
    store.send(.review(.applyPoll(ReviewPollResponse(sessionID: "s-1", status: .ready, review: payload))))

    store.send(.review(.refineCardEditChanged(cardID: card.id, field: .expressionEN, value: "Edited.")))
    store.send(.review(.refineCardEditChanged(cardID: card.id, field: .anchorUserSaid, value: "Edited too.")))

    let shown = try #require(store.state.review.visibleRefineCards.first)
    #expect(shown.key == card.id, "稳定键被编辑改掉了：\(shown.key)")
    #expect(shown.id == card.id, "视图用的身份必须是稳定键")
    #expect(shown.card.id != card.id, "编辑没有真的落到内容上")
    #expect(store.state.review.discardedRefineCardIDs.isEmpty)

    // 按稳定键仍然找得到（这是接收入口要走的那条路）。
    #expect(store.state.review.visibleRefineCard(forKey: card.id)?.card.expressionEN == "Edited.")
    // 再改一次仍然命中同一个草稿，而不是又建一份。
    store.send(.review(.refineCardEditChanged(cardID: card.id, field: .expressionEN, value: "Edited twice.")))
    #expect(store.state.review.visibleRefineCards.count == 1)
    #expect(store.state.review.visibleRefineCard(forKey: card.id)?.card.expressionEN == "Edited twice.")
}

/// 放弃编辑：回到服务端给的那一版。
@Test func revertingAnEditRestoresTheOriginal() throws {
    let payload = try makeReadyPayload()
    let card = try #require(payload.refineCards.first)
    let store = TestStore(initialState: AppState.initial, reducer: appReducer)
    store.send(.review(.applyPoll(ReviewPollResponse(sessionID: "s-1", status: .ready, review: payload))))
    store.send(.review(.refineCardEditChanged(cardID: card.id, field: .intentZH, value: "改过的意图")))

    store.send(.review(.refineCardEditReverted(cardID: card.id)))

    let shown = try #require(store.state.review.visibleRefineCards.first)
    #expect(shown.card == card, "放弃之后内容没回到原样")
    #expect(shown.isEdited == false, "放弃之后还标着「已修改」")
}

/// 给一张**不存在的卡**改字段：静默忽略，**不许留下草稿**。
///
/// 草稿表若接受任意名字，一个拼错的 id 会留下永远清不掉、也永远看不见的垃圾条目 ——
/// 而 `.ready` 的剪枝只按 `validIDs` 走，所以它连被清掉的机会都没有，会一直跟着这份回顾。
@Test func editingACardThatDoesNotExistLeavesNoDraft() throws {
    let payload = try makeReadyPayload()
    let store = TestStore(initialState: AppState.initial, reducer: appReducer)
    store.send(.review(.applyPoll(ReviewPollResponse(sessionID: "s-1", status: .ready, review: payload))))

    store.send(.review(.refineCardEditChanged(cardID: "并不存在的卡", field: .expressionEN, value: "x")))

    #expect(store.state.review.refineCardDrafts.isEmpty, "草稿表收下了一张不存在的卡：\(store.state.review.refineCardDrafts.keys)")
}

/// 丢弃的卡也不许被编辑。
@Test func editingADiscardedCardIsIgnored() throws {
    let payload = try makeReadyPayload()
    let card = try #require(payload.refineCards.first)
    let store = TestStore(initialState: AppState.initial, reducer: appReducer)
    store.send(.review(.applyPoll(ReviewPollResponse(sessionID: "s-1", status: .ready, review: payload))))
    store.send(.review(.discardRefineCardTapped(cardID: card.id)))

    store.send(.review(.refineCardEditChanged(cardID: card.id, field: .expressionEN, value: "x")))

    #expect(store.state.review.refineCardDrafts.isEmpty, "已经丢掉的卡还能被编辑")
}

/// 草稿**不许跨回顾存活** —— 理由与丢弃同：卡的名字是内容派生的，两份不同的回顾可能撞出
/// 同一个名字，于是上一份里改过的英文会**静默改写**这一份里那张同名的卡。
@Test func draftsDoNotOutliveTheirReview() throws {
    let payload = try makeReadyPayload()
    let card = try #require(payload.refineCards.first)
    let store = TestStore(initialState: AppState.initial, reducer: appReducer)
    store.send(.review(.applyPoll(ReviewPollResponse(sessionID: "s-1", status: .ready, review: payload))))
    store.send(.review(.refineCardEditChanged(cardID: card.id, field: .expressionEN, value: "Edited.")))

    store.send(.review(.loadRequested(sessionID: "s-2")))
    #expect(store.state.review.refineCardDrafts.isEmpty, "草稿跟着学员跨了会话：\(store.state.review.refineCardDrafts.keys)")

    var seeded = AppState.initial
    seeded.review.sessionID = "s-1"
    seeded.review.refineCardDrafts = [card.id: card]
    let second = TestStore(initialState: seeded, reducer: appReducer)
    second.send(.review(.applyPoll(ReviewPollResponse(sessionID: "s-1", status: .ready, review: payload))))
    // 这一份产出里有同名卡，所以草稿**留得住** —— 剪枝只剪产出里已经没有的名字。
    #expect(second.state.review.refineCardDrafts.keys.sorted() == [card.id])

    var stale = AppState.initial
    stale.review.sessionID = "s-1"
    stale.review.refineCardDrafts = ["产出里已经没有的卡": card]
    let third = TestStore(initialState: stale, reducer: appReducer)
    third.send(.review(.applyPoll(ReviewPollResponse(sessionID: "s-1", status: .ready, review: payload))))
    #expect(third.state.review.refineCardDrafts.isEmpty, "上一份回顾的草稿粘在了新产出上：\(third.state.review.refineCardDrafts.keys)")
}

/// **入库的是编辑后的那一份。**
///
/// 这条落在中间件：`CorpusBatchAcceptBlockRequest` 本来就带全部五个字段（所以编辑不需要改
/// 接口），而接收入口若仍按 `payload.refineCards` 取卡，学员改完点入库，进语料库的还是原话 ——
/// 编辑形同虚设，且没有任何提示。
@MainActor
@Test func theEditedCardIsWhatGetsSentToTheCorpus() async throws {
    let payload = try makeReadyPayload()
    let card = try #require(payload.refineCards.first)
    let captured = EditedCardCapture()

    let container = Container()
    container.corpusClient.register {
        RecordingAcceptCorpusClient { _, cards in
            captured.record(cards)
            return try makeBatchAcceptResponse(acceptedCount: 1)
        }
    }

    var initialState = AppState.initial
    initialState.review.sessionID = "s-1"
    initialState.review.phase = .ready
    initialState.review.payload = payload

    let store = AppStoreFactory.make(container: container, initialState: initialState)
    store.dispatch(.review(.refineCardEditChanged(
        cardID: card.id,
        field: .expressionEN,
        value: "I'll circle back with the team tomorrow."
    )))
    store.dispatch(.review(.acceptRefineCardTapped(cardID: card.id)))

    try await waitUntil(timeoutNanoseconds: 5_000_000_000) {
        store.state.review.acceptedRefineCardIDs.contains(card.id)
    }

    let sent = try #require(captured.cards?.first)
    #expect(
        sent.expressionEN == "I'll circle back with the team tomorrow.",
        "入库的还是原话，学员的编辑被丢掉了：\(sent.expressionEN)"
    )
    #expect(sent.intentZH == card.intentZH, "没改的字段被顺手带偏了")
}

private final class EditedCardCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RefineCard]?

    func record(_ cards: [RefineCard]) {
        lock.lock()
        defer { lock.unlock() }
        storage = cards
    }

    var cards: [RefineCard]? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class AcceptCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func bump() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class RecordingAcceptCorpusClient: CorpusClientProtocol, @unchecked Sendable {
    private let handler: @Sendable (String, [RefineCard]) async throws -> BatchAcceptBlocksResponse

    init(
        handler: @escaping @Sendable (String, [RefineCard]) async throws -> BatchAcceptBlocksResponse
    ) {
        self.handler = handler
    }

    func listBlocks(
        cursor: String?,
        updatedAfter: String?,
        limit: Int?,
        favoriteOnly: Bool
    ) async throws -> ListPhraseBlocksResponse {
        throw APIError.backend(code: "unexpected", message: "unused")
    }

    func setFavorite(blockID: String, isFavorite: Bool, pinned: Bool) async throws -> PhraseBlock {
        throw APIError.backend(code: "unexpected", message: "unused")
    }

    func deleteBlock(blockID: String) async throws {
        throw APIError.backend(code: "unexpected", message: "unused")
    }

    func batchAccept(
        sourceSessionID: String,
        cards: [RefineCard]
    ) async throws -> BatchAcceptBlocksResponse {
        try await handler(sourceSessionID, cards)
    }
}

private func makeReadyPayload() throws -> ReviewReadyPayload {
    let payload = Data(
        """
        {
          "generator":"ark-review-refine-v1",
          "status":"ready",
          "duration_sec":42,
          "transcript":[
            {"seq":1,"speaker":"user","text":"hello"},
            {"seq":2,"speaker":"ai","text":"hi"}
          ],
          "overview":{
            "goal_achievement":{"met":true,"note":"Met"},
            "issue_count":1,
            "suggestion_count":1,
            "comparison_count":1
          },
          "evaluation":[
            {"layer":"goal","title":"Goal","content":{"met":true}}
          ],
          "dual_column":[
            {"user":"I do it tomorrow.","better":"I'll do it tomorrow."}
          ],
          "refine_cards":[
            {
              "intent_zh":"说明下一步",
              "expression_en":"I'll do it tomorrow.",
              "anchor_user_said":"I do it tomorrow.",
              "scene_tag":"standup",
              "function_tag":"commit"
            }
          ],
          "review":{
            "goal_achievement":{"met":true,"note":"Met"},
            "issues":[
              {"type":"grammar","original_quote":"I do it tomorrow.","hint":"Use future tense."}
            ],
            "suggestions":[
              {"text":"Use will + verb."}
            ],
            "comparisons":[
              {"user":"I do it tomorrow.","better":"I'll do it tomorrow."}
            ]
          },
          "refine":{
            "blocks":[
              {
                "intent_zh":"说明下一步",
                "expression_en":"I'll do it tomorrow.",
                "anchor_user_said":"I do it tomorrow.",
                "scene_tag":"standup",
                "function_tag":"commit"
              }
            ]
          }
        }
        """.utf8
    )
    return try JSONDecoder().decode(ReviewReadyPayload.self, from: payload)
}

private func makeBatchAcceptResponse(acceptedCount: Int) throws -> BatchAcceptBlocksResponse {
    let payload = Data(
        """
        {
          "accepted_count":\(acceptedCount),
          "items":[]
        }
        """.utf8
    )
    return try JSONDecoder().decode(BatchAcceptBlocksResponse.self, from: payload)
}
