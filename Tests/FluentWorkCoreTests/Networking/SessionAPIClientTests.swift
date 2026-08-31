import Foundation
import FluentWorkNetworking
import Moya
import Testing

private enum NetworkClientCancellationTarget: FluentWorkTargetType {
    case delayed

    var baseURL: URL { URL(string: "http://127.0.0.1:8080")! }
    var path: String { "/delayed" }
    var method: Moya.Method { .get }
    var task: Moya.Task { .requestPlain }
    var headers: [String: String]? { nil }
    var sampleData: Data { Data(#"{"ok":true}"#.utf8) }
}

@Test func sessionAPIClientIssuesGuestAndCreatesSession() async throws {
    let guestJSON = Data(
        """
        {
          "user_id":"u-1",
          "is_guest":true,
          "status":"active",
          "access_token":"access-1",
          "refresh_token":"refresh-1",
          "token_type":"Bearer",
          "expires_in":3600
        }
        """.utf8
    )
    let sessionJSON = Data(
        """
        {
          "session_id":"s-1",
          "wss_url":"ws://127.0.0.1:8080/ws",
          "ticket":"ticket-1",
          "ticket_expires_in":60,
          "ticket_expires_at":"2026-08-26T00:00:00Z",
          "scene_type":"demo",
          "status":"created"
        }
        """.utf8
    )

    let client = SessionAPIClient(
        network: StubNetworkClient { target in
            switch target.path {
            case "/auth/guest":
                return guestJSON
            case "/sessions":
                #expect(target.headers?["Authorization"] == "Bearer access-1")
                return sessionJSON
            default:
                Issue.record("unexpected path \(target.path)")
                return Data()
            }
        },
        baseURL: URL(string: "http://127.0.0.1:8080/api/v1")!
    )

    let tokens = try await client.issueGuest(deviceID: "device-1")
    #expect(tokens.accessToken == "access-1")
    #expect(tokens.userID == "u-1")

    let session = try await client.createSession(accessToken: tokens.accessToken)
    #expect(session.sessionID == "s-1")
    #expect(session.ticket == "ticket-1")
    #expect(session.wssURL == "ws://127.0.0.1:8080/ws")
}

@Test func sessionAPIClientNormalizesBackendErrorBody() async throws {
    let errorJSON = Data(
        """
        {"code":"unauthorized","message":"missing token","request_id":"req-1"}
        """.utf8
    )

    let mapped = MoyaNetworkClient.mapHTTPError(statusCode: 401, data: errorJSON)
    #expect(mapped == .backend(code: "unauthorized", message: "missing token"))
}

@Test func sessionAPIClientPollsReviewStatuses() async throws {
    let pending = Data(#"{"session_id":"s-1","status":"pending"}"#.utf8)
    let client = SessionAPIClient(
        network: StubNetworkClient { _ in pending },
        baseURL: URL(string: "http://127.0.0.1:8080/api/v1")!
    )
    let poll = try await client.getSessionReview(sessionID: "s-1", accessToken: "t")
    #expect(poll.status == .pending)
    #expect(poll.sessionID == "s-1")
}

@Test func sessionAPIClientDecodesReadyFullReviewPayload() async throws {
    let ready = Data(
        """
        {
          "session_id":"s-1",
          "status":"ready",
          "review":{
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
        }
        """.utf8
    )
    let client = SessionAPIClient(
        network: StubNetworkClient { _ in ready },
        baseURL: URL(string: "http://127.0.0.1:8080/api/v1")!
    )
    let poll = try await client.getSessionReview(sessionID: "s-1", accessToken: "t")
    #expect(poll.status == .ready)
    #expect(poll.review?.generator == "ark-review-refine-v1")
    #expect(poll.review?.transcript.count == 2)
    #expect(poll.review?.refineCards.count == 1)
}

@Test func sessionAPIClientPostsDegradedTextMessage() async throws {
    let replyJSON = Data(
        """
        {"session_id":"s-1","reply":"stub hi","channel":"text","generator":"stub-text-v1"}
        """.utf8
    )
    let client = SessionAPIClient(
        network: StubNetworkClient { target in
            #expect(target.path == "/sessions/s-1/messages")
            #expect(target.headers?["Authorization"] == "Bearer t")
            if case let .requestParameters(parameters, _) = target.task {
                #expect(parameters["text"] as? String == "hi")
                #expect(parameters["channel"] as? String == "text")
            } else {
                Issue.record("expected JSON body parameters")
            }
            return replyJSON
        },
        baseURL: URL(string: "http://127.0.0.1:8080/api/v1")!
    )
    let reply = try await client.sendSessionMessage(
        sessionID: "s-1",
        accessToken: "t",
        text: "hi",
        channel: "text"
    )
    #expect(reply.reply == "stub hi")
    #expect(reply.generator == "stub-text-v1")
    #expect(reply.channel == "text")
}

@Test func sessionAPIClientMergesGuestAccount() async throws {
    let json = Data(
        """
        {"user_id":"u-2","is_guest":false,"merged_from_user_id":"u-1","already_merged":false}
        """.utf8
    )
    let client = SessionAPIClient(
        network: StubNetworkClient { target in
            #expect(target.path == "/account/merge")
            #expect(target.headers?["Authorization"] == "Bearer access-1")
            return json
        },
        baseURL: URL(string: "http://127.0.0.1:8080/api/v1")!
    )
    let merged = try await client.mergeGuestAccount(deviceID: "device-1", accessToken: "access-1")
    #expect(merged.userID == "u-2")
    #expect(merged.alreadyMerged == false)
}

@Test func moyaNetworkClientMapsCancellationToAPIErrorCancelled() async {
    let provider = MoyaProvider<MultiTarget>(stubClosure: MoyaProvider.delayedStub(1.0))
    let client = MoyaNetworkClient(provider: provider)

    let task = Swift.Task {
        try await client.requestData(for: NetworkClientCancellationTarget.delayed)
    }

    await Swift.Task.yield()
    task.cancel()

    do {
        _ = try await task.value
        Issue.record("expected cancellation")
    } catch let error as APIError {
        #expect(error == .cancelled)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}
