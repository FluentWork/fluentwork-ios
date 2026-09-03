import FactoryKit
import FluentWorkNetworking
import Foundation

private actor ActiveSessionBox {
    private var sessionID: String?

    func get() -> String? {
        sessionID
    }

    func set(_ sessionID: String?) {
        self.sessionID = sessionID
    }
}

/// Speaks-room session facade: guest token → POST /sessions → WSS connect.
public final class DefaultSpeechSessionClient: SpeechSessionClientProtocol, @unchecked Sendable {
    private let api: SessionAPIClientProtocol
    private let tokens: AuthTokenStoreProtocol
    private let transport: SocketTransportProtocol
    private let activeSession = ActiveSessionBox()

    public init(
        api: SessionAPIClientProtocol,
        tokens: AuthTokenStoreProtocol,
        transport: SocketTransportProtocol
    ) {
        self.api = api
        self.tokens = tokens
        self.transport = transport
    }

    public func startSession() async throws {
        let deviceID = try await tokens.deviceID()
        let created: CreateSessionResponse
        do {
            let accessToken = try await ensureAccessToken(deviceID: deviceID)
            created = try await api.createSession(
                accessToken: accessToken,
                materialID: nil,
                sceneType: "demo"
            )
        } catch let error as APIError {
            // Cached token rejected by backend (e.g., backend JWT secret changed
            // between environments, or token issued by a different backend,
            // or DB was reset so cached user_id no longer exists).
            // Clear and reissue a fresh guest token, then retry once.
            guard case .backend(let code, _) = error, Self.isAuthFailureCode(code) else {
                throw error
            }
            print("[🔑 Token] Cached token rejected (\(code)), clearing keychain and reissuing...")
            try await tokens.clear()
            let freshToken = try await ensureAccessToken(deviceID: deviceID)
            created = try await api.createSession(
                accessToken: freshToken,
                materialID: nil,
                sceneType: "demo"
            )
        }
        guard let wssURL = URL(string: created.wssURL) else {
            throw APIError.backend(
                code: "invalid_wss_url",
                message: "Session returned an invalid WSS URL."
            )
        }

        await activeSession.set(created.sessionID)
        do {
            try await transport.connect(
                url: wssURL,
                sessionID: created.sessionID,
                ticket: created.ticket
            )
            try await transport.send(
                control: .sessionStart(
                    .init(scene: "demo")
                )
            )
        } catch {
            await transport.disconnect()
            await activeSession.set(nil)
            throw error
        }
    }

    public func activeSessionID() async -> String? {
        await activeSession.get()
    }

    public func submitTranscript(_ text: String) async {
        // Interrupt marker from SpeechSession middleware.
        guard text == "__interrupt__" else { return }
        await transport.markInterrupted()
        try? await transport.send(control: .interrupt)
    }

    public func sendSpeechBoundary(started: Bool, turnID: String?, text: String?) async throws {
        if started {
            try await transport.send(control: .userSpeechStart)
        } else {
            // Backend uses turnID for badge hit dedupe. text is optional client ASR result (B13).
            try await transport.send(control: .userSpeechEnd(text: text, turnID: turnID))
        }
    }

    public func sendAudioPCM(_ data: Data) async throws {
        try await transport.send(audio: data)
    }

    public func transportEvents() -> AsyncStream<SocketTransportEvent> {
        transport.events
    }

    public func sendDegradedTextMessage(_ text: String) async throws -> PostMessageResponse {
        let sessionID = try await requireActiveSessionID()
        return try await withAuthRecovery { accessToken in
            try await api.sendSessionMessage(
                sessionID: sessionID,
                accessToken: accessToken,
                text: text,
                channel: "text"
            )
        }
    }

    public func pollReview(sessionID: String) async throws -> ReviewPollResponse {
        try await withAuthRecovery { accessToken in
            try await api.getSessionReview(sessionID: sessionID, accessToken: accessToken)
        }
    }

    public func mergeGuestAccount() async throws -> MergeResponse {
        let deviceID = try await tokens.deviceID()
        return try await withAuthRecovery { accessToken in
            try await api.mergeGuestAccount(deviceID: deviceID, accessToken: accessToken)
        }
    }

    public func endSession() async {
        // The gateway persists the session (and enqueues the review job) only
        // when it receives an explicit `session.end` control frame. Closing the
        // socket without it leaves the session in a pending/active state.
        try? await transport.send(control: .sessionEnd(reason: "user"))
        await transport.disconnect()
        await activeSession.set(nil)
    }

    private func ensureAccessToken(deviceID: String) async throws -> String {
        // Use loadAccessToken which checks expiration; fall back to re-issuing if expired or absent.
        if let cached = try await tokens.loadAccessToken() {
            let now = Date()
            let buffer: TimeInterval = 60 // Refresh 60s before actual expiry
            if cached.expiresAt.timeIntervalSince(now) > buffer {
                print("[🔑 Token] Using cached token (expires in \(Int(cached.expiresAt.timeIntervalSince(now)))s): \(cached.value.prefix(20))...")
                return cached.value
            }
            print("[🔑 Token] Cached token expired or expiring soon, re-issuing...")
        } else {
            print("[🔑 Token] No cached token, issuing guest for deviceID: \(deviceID)")
        }
        let issued = try await api.issueGuest(deviceID: deviceID)
        print("[🔑 Token] Received new token: \(issued.accessToken.prefix(20))...")
        try await tokens.save(tokens: issued, deviceID: deviceID)
        print("[🔑 Token] Saved token to keychain")
        return issued.accessToken
    }

    private func requireAccessToken() async throws -> String {
        let deviceID = try await tokens.deviceID()
        return try await ensureAccessToken(deviceID: deviceID)
    }

    private func requireActiveSessionID() async throws -> String {
        guard let sessionID = await activeSession.get(), !sessionID.isEmpty else {
            throw APIError.backend(
                code: "no_active_session",
                message: "No active speaking-room session."
            )
        }
        return sessionID
    }

    /// Wraps an authenticated session API call with automatic 401 recovery.
    /// On UNAUTHENTICATED/http_401, clears the cached token, reissues a fresh
    /// guest token, and retries once. Without this, a stale token (e.g., from a
    /// previous DB environment) would surface as "invalid access token" to the UI.
    private func withAuthRecovery<T>(_ operation: (String) async throws -> T) async throws -> T {
        let deviceID = try await tokens.deviceID()
        do {
            let token = try await ensureAccessToken(deviceID: deviceID)
            return try await operation(token)
        } catch let error as APIError {
            guard case .backend(let code, _) = error,
                  Self.isAuthFailureCode(code) else {
                throw error
            }
            print("[🔑 Token] Cached token rejected (\(code)), clearing keychain and reissuing...")
            try await tokens.clear()
            let freshToken = try await ensureAccessToken(deviceID: deviceID)
            return try await operation(freshToken)
        }
    }

    private static func isAuthFailureCode(_ code: String) -> Bool {
        code == "UNAUTHENTICATED" || code == "unauthenticated"
            || code == "unauthorized" || code == "http_401"
    }
}
