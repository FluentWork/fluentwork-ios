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

        func startSession() async throws {}
        func sendSpeechBoundary(started: Bool, turnID: String?, text: String?) async throws {}
        func sendAudioPCM(_ data: Data) async throws {}
        func submitTranscript(_ text: String) async {}
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
    try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.review.phase == .ready
    }

    #expect(store.state.review.phase == .ready)
    #expect(store.state.review.payload?.generator == "ark-review-refine-v1")
    #expect(store.state.review.payload?.transcript.count == 2)
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

    try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
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

    try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
        store.state.review.acceptErrorMessage == "accept denied"
    }

    #expect(store.state.review.acceptingRefineCardIDs.isEmpty)
    #expect(store.state.review.acceptedRefineCardIDs.isEmpty)
    #expect(store.state.review.acceptErrorMessage == "accept denied")
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

@MainActor
private func waitUntil(
    timeoutNanoseconds: UInt64,
    pollIntervalNanoseconds: UInt64 = 10_000_000,
    condition: @escaping @MainActor () -> Bool
) async throws {
    let start = DispatchTime.now().uptimeNanoseconds
    while !condition() {
        if DispatchTime.now().uptimeNanoseconds - start >= timeoutNanoseconds {
            throw TimeoutError()
        }
        try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
    }
}

private struct TimeoutError: Error {}
