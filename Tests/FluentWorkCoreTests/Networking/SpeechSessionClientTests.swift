import FactoryKit
import Foundation
import FluentWorkNetworking
import Testing
@testable import FluentWorkCore

private actor FailingSessionStartTransport: SocketTransportProtocol {
    enum StubError: Error, Equatable {
        case sessionStartFailed
    }

    nonisolated let events: AsyncStream<SocketTransportEvent>
    private let continuation: AsyncStream<SocketTransportEvent>.Continuation
    private(set) var disconnectCount = 0

    init() {
        let pair = AsyncStream.makeStream(of: SocketTransportEvent.self)
        self.events = pair.stream
        self.continuation = pair.continuation
    }

    func connect(url: URL, sessionID: String, ticket: String) async throws {}

    func disconnect() async {
        disconnectCount += 1
        continuation.finish()
    }

    func send(control frame: WSControlFrame) async throws {
        if case .sessionStart = frame {
            throw StubError.sessionStartFailed
        }
    }

    func send(audio data: Data) async throws {}

    func markInterrupted() async {}
}

@Test func authTokenStorePersistsGuestTokens() async throws {
    let storage = InMemorySecureStorage()
    let deviceUUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let store = SecureAuthTokenStore(
        storage: storage,
        idGenerator: FixedIDGenerator(value: deviceUUID)
    )

    let deviceID = try await store.deviceID()
    #expect(deviceID == deviceUUID.uuidString)

    try await store.save(
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
    #expect(try await store.accessToken() == "a")
    #expect(try await store.deviceID() == deviceUUID.uuidString)
}

private final class RecordingSpeechSessionTokenStore: AuthTokenStoreProtocol, @unchecked Sendable {
    private let deviceIDValue: String
    private(set) var savedTokenResponse: TokenResponse?
    var seededAccessToken: AuthToken?

    init(deviceID: String, seededAccessToken: AuthToken? = nil) {
        self.deviceIDValue = deviceID
        self.seededAccessToken = seededAccessToken
    }

    func deviceID() async throws -> String { deviceIDValue }
    func accessToken() async throws -> String? { seededAccessToken?.value }
    func save(tokens: TokenResponse, deviceID: String) async throws {
        savedTokenResponse = tokens
        seededAccessToken = AuthToken(
            value: tokens.accessToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(tokens.expiresIn))
        )
    }
    func clear() async throws {
        seededAccessToken = nil
        savedTokenResponse = nil
    }
    func userID() async throws -> String? { nil }
    func isGuest() async throws -> Bool { true }
    func loadAccessToken() async throws -> AuthToken? { seededAccessToken }
    func saveAccessToken(_ token: AuthToken) async throws { seededAccessToken = token }
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
    #expect(try await tokenStore.accessToken() == "access-1")

    let calls = await transport.connectCalls
    #expect(calls.count == 1)
    #expect(calls[0].sessionID == "s-9")
    #expect(calls[0].ticket == "tik")
    let sentControls = await transport.sentControlFrames
    #expect(sentControls == [.sessionStart(.init(scene: "demo"))])
}

@MainActor
@Test func defaultSpeechSessionClientRefreshesExpiringAccessTokenBeforeCreateSession() async throws {
    let transport = InMemorySocketTransport()
    let tokenStore = RecordingSpeechSessionTokenStore(
        deviceID: "expiring-device",
        seededAccessToken: AuthToken(
            value: "stale-access",
            expiresAt: Date().addingTimeInterval(30)
        )
    )

    let guestJSON = Data(
        """
        {"user_id":"u-refresh","is_guest":true,"status":"active","access_token":"fresh-access","refresh_token":"r","token_type":"Bearer","expires_in":3600}
        """.utf8
    )
    let sessionJSON = Data(
        """
        {"session_id":"s-refresh","wss_url":"ws://127.0.0.1:9/ws","ticket":"tik","ticket_expires_in":60,"ticket_expires_at":"2026-08-26T00:00:00Z","scene_type":"demo","status":"created"}
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

    #expect(tokenStore.savedTokenResponse?.accessToken == "fresh-access")
    #expect(try await tokenStore.accessToken() == "fresh-access")
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

    await transport.emitControl(.feedbackBadge(badge: "表达自然", phraseBlockID: "block-1", tier: .soft))
    let first = await task.value
    #expect(
        first == .control(.feedbackBadge(badge: "表达自然", phraseBlockID: "block-1", tier: .soft))
    )
}

// Mock-mode coverage of runbook §3 Case 1 — turn_id monotonic across multiple
// speech boundaries. Mirrors what a real device + Charles capture would prove:
// two consecutive `user.speech.end` frames must carry turn_id "turn-1" then
// "turn-2" with no gaps and no duplicates. Day-one DefaultSpeechSessionClient
// always sends `text: nil` because client ASR lands in B13; once B13 ships,
// this test extends to also assert `text: "..."` is carried.
@MainActor
@Test func defaultSpeechSessionClientSendsMonotonicTurnIDsAcrossMultipleTurns() async throws {
    let transport = InMemorySocketTransport()
    try await transport.connect(
        url: URL(string: "ws://127.0.0.1/ws")!,
        sessionID: "s-1",
        ticket: "ticket"
    )
    let storage = InMemorySecureStorage()
    let tokenStore = SecureAuthTokenStore(
        storage: storage,
        idGenerator: FixedIDGenerator(value: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!)
    )

    let client = DefaultSpeechSessionClient(
        api: SessionAPIClient(
            network: StubNetworkClient { _ in Data() },
            baseURL: URL(string: "http://127.0.0.1:8080/api/v1")!
        ),
        tokens: tokenStore,
        transport: transport
    )

    // Turn 1.
    try await client.sendSpeechBoundary(started: true, turnID: nil, text: nil)
    try await client.sendAudioPCM(Data([0x10, 0x11]))
    try await client.sendSpeechBoundary(started: false, turnID: "turn-1", text: nil)

    // Turn 2 (no client ASR yet → text: nil per B13-not-shipped contract).
    try await client.sendSpeechBoundary(started: true, turnID: nil, text: nil)
    try await client.sendAudioPCM(Data([0x20, 0x21]))
    try await client.sendSpeechBoundary(started: false, turnID: "turn-2", text: nil)

    let sentControls = await transport.sentControlFrames
    #expect(
        sentControls == [
            .userSpeechStart,
            .userSpeechEnd(text: nil, turnID: "turn-1"),
            .userSpeechStart,
            .userSpeechEnd(text: nil, turnID: "turn-2"),
        ]
    )

    let sentAudio = await transport.sentAudioPayloads
    #expect(sentAudio == [Data([0x10, 0x11]), Data([0x20, 0x21])])
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

    try await client.sendSpeechBoundary(started: true, turnID: nil, text: nil)
    try await client.sendAudioPCM(Data([0x00, 0x01, 0x02]))
    try await client.sendSpeechBoundary(started: false, turnID: "turn-1", text: nil)

    // Day-one DefaultSpeechSessionClient takes the server-side ASR path —
    // it always sends `text: nil` so the gateway does the hit-detection
    // off the vendor's ASR transcript. When B12 exposes a client ASR
    // path (B13 audio engine), `text` will be populated from a client
    // transcript before the boundary goes out.
    let sentControls = await transport.sentControlFrames
    #expect(sentControls == [.userSpeechStart, .userSpeechEnd(text: nil, turnID: "turn-1")])
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

@MainActor
@Test func defaultSpeechSessionClientClearsActiveSessionWhenStartFails() async throws {
    let transport = FailingSessionStartTransport()
    let storage = InMemorySecureStorage()
    let tokenStore = SecureAuthTokenStore(
        storage: storage,
        idGenerator: FixedIDGenerator(value: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!)
    )

    let guestJSON = Data(
        """
        {"user_id":"u-1","is_guest":true,"status":"active","access_token":"access-1","refresh_token":"r","token_type":"Bearer","expires_in":3600}
        """.utf8
    )
    let sessionJSON = Data(
        """
        {"session_id":"s-11","wss_url":"ws://127.0.0.1:9/ws","ticket":"tik","ticket_expires_in":60,"ticket_expires_at":"2026-08-26T00:00:00Z","scene_type":"demo","status":"created"}
        """.utf8
    )

    let api = SessionAPIClient(
        network: StubNetworkClient { target in
            switch target.path {
            case "/auth/guest": return guestJSON
            case "/sessions": return sessionJSON
            case "/sessions/s-11/messages":
                return Data(#"{"session_id":"s-11","reply":"ok","channel":"text","generator":"stub"}"#.utf8)
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

    do {
        try await client.startSession()
        Issue.record("expected start session failure")
    } catch let error as FailingSessionStartTransport.StubError {
        #expect(error == .sessionStartFailed)
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    do {
        _ = try await client.sendDegradedTextMessage("after-failure")
        Issue.record("expected no active session error after failed start")
    } catch let error as APIError {
        #expect(error == .backend(
            code: "no_active_session",
            message: "No active speaking-room session."
        ))
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    #expect(await transport.disconnectCount == 1)
}
