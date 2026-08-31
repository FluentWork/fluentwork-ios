import Foundation
import FluentWorkNetworking
import Testing

@Test func corpusAPIClientListsBlocksWithCursorFilters() async throws {
    let payload = Data(
        """
        {
          "items":[
            {
              "id":"b-1",
              "intent_zh":"说明下一步",
              "expression_en":"I'll follow up tomorrow.",
              "anchor_user_said":"I will follow up tomorrow.",
              "scene_tag":"standup",
              "function_tag":"commit",
              "state":"new",
              "success_streak":0,
              "next_due_at":"2026-09-01T00:00:00Z",
              "ease_factor":2.5,
              "real_use_count":0,
              "is_favorite":false,
              "pinned_at":null,
              "source_session_id":"s-1",
              "created_at":"2026-08-31T00:00:00Z",
              "updated_at":"2026-08-31T00:00:00Z"
            }
          ],
          "next_cursor":"cursor-2"
        }
        """.utf8
    )

    let client = CorpusAPIClient(
        network: StubNetworkClient { target in
            #expect(target.path == "/corpus/blocks")
            #expect(target.headers?["Authorization"] == "Bearer access-1")
            if case let .requestParameters(parameters, _) = target.task {
                #expect(parameters["scene"] as? String == "standup")
                #expect(parameters["func"] as? String == "commit")
                #expect(parameters["kw"] as? String == "follow")
                #expect(parameters["cursor"] as? String == "cursor-1")
                #expect(parameters["limit"] as? Int == 20)
                #expect(parameters["favorite_only"] as? Bool == true)
            } else {
                Issue.record("expected query parameters")
            }
            return payload
        },
        baseURL: URL(string: "http://127.0.0.1:8080/api/v1")!
    )

    let response = try await client.listBlocks(
        accessToken: "access-1",
        scene: "standup",
        function: "commit",
        keyword: "follow",
        cursor: "cursor-1",
        limit: 20,
        favoriteOnly: true
    )
    #expect(response.items.count == 1)
    #expect(response.items[0].id == "b-1")
    #expect(response.nextCursor == "cursor-2")
}

@Test func corpusAPIClientBatchAcceptsRefineBlocks() async throws {
    let payload = Data(
        """
        {
          "accepted_count":1,
          "items":[
            {
              "id":"b-1",
              "intent_zh":"说明下一步",
              "expression_en":"I'll follow up tomorrow.",
              "anchor_user_said":"I will follow up tomorrow.",
              "scene_tag":"standup",
              "function_tag":"commit",
              "state":"new",
              "success_streak":0,
              "next_due_at":"2026-09-01T00:00:00Z",
              "ease_factor":2.5,
              "real_use_count":0,
              "is_favorite":false,
              "pinned_at":null,
              "source_session_id":"s-1",
              "created_at":"2026-08-31T00:00:00Z",
              "updated_at":"2026-08-31T00:00:00Z"
            }
          ]
        }
        """.utf8
    )

    let client = CorpusAPIClient(
        network: StubNetworkClient { target in
            #expect(target.path == "/corpus/blocks/batch-accept")
            if case let .requestJSONEncodable(encodable) = target.task {
                let data = try JSONEncoder().encode(AnyEncodable(encodable))
                let body = try JSONDecoder().decode(CorpusBatchAcceptRequest.self, from: data)
                #expect(body.sourceSessionID == "s-1")
                #expect(body.blocks.count == 1)
                #expect(body.blocks[0].functionTag == "commit")
            } else {
                Issue.record("expected JSON encodable request")
            }
            return payload
        },
        baseURL: URL(string: "http://127.0.0.1:8080/api/v1")!
    )

    let response = try await client.batchAccept(
        accessToken: "access-1",
        sourceSessionID: "s-1",
        blocks: [
            CorpusBatchAcceptBlockRequest(
                intentZH: "说明下一步",
                expressionEN: "I'll follow up tomorrow.",
                anchorUserSaid: "I will follow up tomorrow.",
                sceneTag: "standup",
                functionTag: "commit"
            )
        ]
    )
    #expect(response.acceptedCount == 1)
    #expect(response.items.first?.sourceSessionID == "s-1")
}

@Test func corpusAPIClientFavoritesUpdatesAndDeletesBlock() async throws {
    let payload = Data(
        """
        {
          "id":"b-1",
          "intent_zh":"说明下一步",
          "expression_en":"I'll follow up tomorrow.",
          "anchor_user_said":"I will follow up tomorrow.",
          "scene_tag":"standup",
          "function_tag":"commit",
          "state":"new",
          "success_streak":0,
          "next_due_at":"2026-09-01T00:00:00Z",
          "ease_factor":2.5,
          "real_use_count":0,
          "is_favorite":true,
          "pinned_at":"2026-08-31T01:00:00Z",
          "source_session_id":"s-1",
          "created_at":"2026-08-31T00:00:00Z",
          "updated_at":"2026-08-31T01:00:00Z"
        }
        """.utf8
    )
    let deletePayload = Data(#"{"deleted":true}"#.utf8)

    let client = CorpusAPIClient(
        network: StubNetworkClient { target in
            switch target.path {
            case "/corpus/blocks/b-1/favorite":
                if case let .requestJSONEncodable(encodable) = target.task {
                    let data = try JSONEncoder().encode(AnyEncodable(encodable))
                    let body = try JSONDecoder().decode(FavoriteCorpusBlockRequest.self, from: data)
                    #expect(body.isFavorite == true)
                    #expect(body.pinned == true)
                } else {
                    Issue.record("expected favorite body")
                }
                return payload
            case "/corpus/blocks/b-1":
                switch target.method {
                case .put:
                    if case let .requestJSONEncodable(encodable) = target.task {
                        let data = try JSONEncoder().encode(AnyEncodable(encodable))
                        let body = try JSONDecoder().decode(UpdateCorpusBlockRequest.self, from: data)
                        #expect(body.intentZH == "说明新的下一步")
                    } else {
                        Issue.record("expected update body")
                    }
                    return payload
                case .delete:
                    return deletePayload
                default:
                    Issue.record("unexpected method \(target.method.rawValue)")
                    return Data()
                }
            default:
                Issue.record("unexpected path \(target.path)")
                return Data()
            }
        },
        baseURL: URL(string: "http://127.0.0.1:8080/api/v1")!
    )

    let favorited = try await client.favoriteBlock(
        accessToken: "access-1",
        blockID: "b-1",
        isFavorite: true,
        pinned: true
    )
    #expect(favorited.isFavorite == true)

    let updated = try await client.updateBlock(
        accessToken: "access-1",
        blockID: "b-1",
        request: UpdateCorpusBlockRequest(
            intentZH: "说明新的下一步",
            expressionEN: "I'll send the update this afternoon.",
            anchorUserSaid: "I will send the update later.",
            sceneTag: "standup",
            functionTag: "commit"
        )
    )
    #expect(updated.id == "b-1")

    let deleted = try await client.deleteBlock(accessToken: "access-1", blockID: "b-1")
    #expect(deleted.deleted == true)
}

private struct AnyEncodable: Encodable {
    private let encodeImpl: (Encoder) throws -> Void

    init(_ encodable: Encodable) {
        self.encodeImpl = { encoder in
            try encodable.encode(to: encoder)
        }
    }

    func encode(to encoder: Encoder) throws {
        try encodeImpl(encoder)
    }
}
