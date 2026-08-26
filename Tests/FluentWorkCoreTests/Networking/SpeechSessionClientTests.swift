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
}
