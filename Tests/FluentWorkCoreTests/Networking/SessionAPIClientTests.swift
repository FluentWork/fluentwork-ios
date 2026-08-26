import Foundation
import FluentWorkNetworking
import Testing

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

@Test func sessionAPIClientMessagesEndpointIsWiredButUnavailable() async {
    let client = SessionAPIClient(
        network: StubNetworkClient { _ in Data() },
        baseURL: URL(string: "http://127.0.0.1:8080/api/v1")!
    )
    do {
        try await client.sendSessionMessage(sessionID: "s-1", accessToken: "t", text: "hi")
        Issue.record("expected messages_not_implemented")
    } catch let error as APIError {
        #expect(error == .backend(
            code: "messages_not_implemented",
            message: "POST /sessions/{id}/messages is not available until backend B7."
        ))
    } catch {
        Issue.record("unexpected error \(error)")
    }
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
