import FactoryKit
import Foundation
import FluentWorkNetworking
import Testing
@testable import FluentWorkCore

@Test func authTokenStorePersistsGuestTokens() throws {
    let storage = InMemorySecureStorage()
    let deviceUUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let store = SecureAuthTokenStore(
        storage: storage,
        idGenerator: FixedIDGenerator(value: deviceUUID)
    )

    let deviceID = try store.deviceID()
    #expect(deviceID == deviceUUID.uuidString)

    try store.save(
        tokens: TokenResponse(
            userID: "u-1",
            isGuest: true,
            status: "active",
            accessToken: "a",
            refreshToken: "r",
            expiresIn: 60
        ),
        deviceID: deviceID
    )
    #expect(try store.accessToken() == "a")
    #expect(try store.deviceID() == deviceUUID.uuidString)
}

@MainActor
@Test func defaultSpeechSessionClientCreatesSessionAndConnectsSocket() async throws {
    Container.shared.reset()
    defer { Container.shared.reset() }

    let transport = InMemorySocketTransport()
    let storage = InMemorySecureStorage()
    let tokenStore = SecureAuthTokenStore(
        storage: storage,
        idGenerator: FixedIDGenerator(value: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
    )

    let guestJSON = Data(
        """
        {"user_id":"u-1","is_guest":true,"status":"active","access_token":"access-1","refresh_token":"r","token_type":"Bearer","expires_in":3600}
        """.utf8
    )
    let sessionJSON = Data(
        """
        {"session_id":"s-9","wss_url":"ws://127.0.0.1:9/ws","ticket":"tik","ticket_expires_in":60,"ticket_expires_at":"2026-08-26T00:00:00Z","scene_type":"demo","status":"created"}
        """.utf8
    )

    let api = SessionAPIClient(
        network: StubNetworkClient { target in
            switch target.path {
            case "/auth/guest": return guestJSON
            case "/sessions": return sessionJSON
            default:
                Issue.record("unexpected \(target.path)")
                return Data()
            }
        },
        baseURL: URL(string: "http://127.0.0.1:8080/api/v1")!
    )

    let client = DefaultSpeechSessionClient(
        api: api,
        tokens: tokenStore,
        transport: transport
    )

    try await client.startSession()
    #expect(try tokenStore.accessToken() == "access-1")

    let calls = await transport.connectCalls
    #expect(calls.count == 1)
    #expect(calls[0].sessionID == "s-9")
    #expect(calls[0].ticket == "tik")
    let sentControls = await transport.sentControlFrames
    #expect(sentControls == [.sessionStart(.init(scene: "demo"))])
}

@MainActor
@Test func defaultSpeechSessionClientExposesTransportEventsStream() async throws {
    let transport = InMemorySocketTransport()
    let storage = InMemorySecureStorage()
    let tokenStore = SecureAuthTokenStore(
        storage: storage,
        idGenerator: FixedIDGenerator(value: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!)
    )

    let client = DefaultSpeechSessionClient(
        api: SessionAPIClient(
            network: StubNetworkClient { _ in Data() },
            baseURL: URL(string: "http://127.0.0.1:8080/api/v1")!
        ),
        tokens: tokenStore,
        transport: transport
    )

    let stream = client.transportEvents()
    let task = Task { () -> SocketTransportEvent? in
        for await event in stream {
            return event
        }
        return nil
    }

    await transport.emitControl(.feedbackBadge(badge: "表达自然"))
    let first = await task.value
    #expect(first == .control(.feedbackBadge(badge: "表达自然")))
}

@MainActor
@Test func defaultSpeechSessionClientSendsSpeechBoundaryAndPCM() async throws {
    let transport = InMemorySocketTransport()
    try await transport.connect(
        url: URL(string: "ws://127.0.0.1/ws")!,
        sessionID: "s-1",
        ticket: "ticket"
    )
    let storage = InMemorySecureStorage()
    let tokenStore = SecureAuthTokenStore(
        storage: storage,
        idGenerator: FixedIDGenerator(value: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!)
    )

    let client = DefaultSpeechSessionClient(
        api: SessionAPIClient(
            network: StubNetworkClient { _ in Data() },
            baseURL: URL(string: "http://127.0.0.1:8080/api/v1")!
        ),
        tokens: tokenStore,
        transport: transport
    )

    try await client.sendSpeechBoundary(started: true)
    try await client.sendAudioPCM(Data([0x00, 0x01, 0x02]))
    try await client.sendSpeechBoundary(started: false)

    let sentControls = await transport.sentControlFrames
    #expect(sentControls == [.userSpeechStart, .userSpeechEnd])
    let sentAudio = await transport.sentAudioPayloads
    #expect(sentAudio == [Data([0x00, 0x01, 0x02])])
}

@MainActor
@Test func defaultSpeechSessionClientClearsActiveSessionWhenEnded() async throws {
    let transport = InMemorySocketTransport()
    let storage = InMemorySecureStorage()
    let tokenStore = SecureAuthTokenStore(
        storage: storage,
        idGenerator: FixedIDGenerator(value: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!)
    )

    let guestJSON = Data(
        """
        {"user_id":"u-1","is_guest":true,"status":"active","access_token":"access-1","refresh_token":"r","token_type":"Bearer","expires_in":3600}
        """.utf8
    )
    let sessionJSON = Data(
        """
        {"session_id":"s-10","wss_url":"ws://127.0.0.1:9/ws","ticket":"tik","ticket_expires_in":60,"ticket_expires_at":"2026-08-26T00:00:00Z","scene_type":"demo","status":"created"}
        """.utf8
    )

    let api = SessionAPIClient(
        network: StubNetworkClient { target in
            switch target.path {
            case "/auth/guest": return guestJSON
            case "/sessions": return sessionJSON
            case "/sessions/s-10/messages":
                return Data(#"{"session_id":"s-10","reply":"ok","channel":"text","generator":"stub"}"#.utf8)
            default:
                Issue.record("unexpected \(target.path)")
                return Data()
            }
        },
        baseURL: URL(string: "http://127.0.0.1:8080/api/v1")!
    )

    let client = DefaultSpeechSessionClient(
        api: api,
        tokens: tokenStore,
        transport: transport
    )

    try await client.startSession()
    let reply = try await client.sendDegradedTextMessage("hi")
    #expect(reply.sessionID == "s-10")

    await client.endSession()

    do {
        _ = try await client.sendDegradedTextMessage("after-end")
        Issue.record("expected no active session error")
    } catch let error as APIError {
        #expect(error == .backend(
            code: "no_active_session",
            message: "No active speaking-room session."
        ))
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}
