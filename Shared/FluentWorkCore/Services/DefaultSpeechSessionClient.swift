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

private actor HeartbeatTaskBox {
    private var task: Task<Void, Never>?

    func set(_ task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

/// Speaks-room session facade: guest token → POST /sessions → WSS connect.
public final class DefaultSpeechSessionClient: SpeechSessionClientProtocol, @unchecked Sendable {
    private let api: SessionAPIClientProtocol
    private let tokens: AuthTokenStoreProtocol
    private let transport: SocketTransportProtocol
    private let activeSession = ActiveSessionBox()
    private let heartbeatTask = HeartbeatTaskBox()
    private let heartbeatInterval: Duration

    public init(
        api: SessionAPIClientProtocol,
        tokens: AuthTokenStoreProtocol,
        transport: SocketTransportProtocol,
        heartbeatInterval: Duration = .seconds(30)
    ) {
        self.api = api
        self.tokens = tokens
        self.transport = transport
        self.heartbeatInterval = heartbeatInterval
    }

    public func startSession(continueFromSessionID: String?) async throws {
        let deviceID = try await tokens.deviceID()
        let created: CreateSessionResponse
        do {
            let accessToken = try await ensureAccessToken(deviceID: deviceID)
            created = try await api.createSession(
                accessToken: accessToken,
                materialID: nil,
                sceneType: "standup"
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
                sceneType: "standup"
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
                    .init(sceneType: "standup", continueFromSessionID: continueFromSessionID)
                )
            )
        } catch {
            await heartbeatTask.cancel()
            await transport.disconnect()
            await activeSession.set(nil)
            throw error
        }
        await startHeartbeat()
    }

    /// Keeps the gateway's read-idle timer fed. Doubles as the clock probe.
    ///
    /// Why `ts` is 0 rather than the phone's clock: the gateway answers a ping
    /// with a pong carrying our own `ts` back, and substitutes **its own** clock
    /// only when that `ts` is 0 (`voicegateway/handler.go`). A stamped ping
    /// therefore buys an echo, never an offset — and an echo is the dangerous
    /// kind of wrong, because it yields a plausible few-millisecond skew instead
    /// of an obvious failure. ``URLSessionSocketTransport`` normalises the same
    /// way on the way out; sending 0 here keeps the intent readable at the call
    /// site instead of leaving it as a property of the transport.
    ///
    /// The opening ping goes out immediately rather than after one interval.
    /// Sleeping first would leave the **first** turn — the one whose
    /// first-response latency anyone actually looks at — with no offset to
    /// measure against, so its latency would read as unmeasurable for the
    /// 30 s it takes the heartbeat to come round.
    private func startHeartbeat() async {
        await heartbeatTask.cancel()
        let transport = self.transport
        let interval = self.heartbeatInterval
        let task = Task { [transport] in
            while !Task.isCancelled {
                try? await transport.send(control: .ping(ts: 0))
                try? await Task.sleep(for: interval)
            }
        }
        await heartbeatTask.set(task)
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

    public func sendTurnAbort(turnID: String, outcome: TurnOutcome) async throws {
        guard let wire = Self.abortWireOutcome(outcome) else { return }
        try await transport.send(control: .clientTurnAbort(turnID: turnID, outcome: wire))
    }

    private static func abortWireOutcome(
        _ outcome: TurnOutcome
    ) -> WSControlFrame.ClientTurnAbortOutcome? {
        switch outcome {
        case .ok:
            return nil
        case .timeout:
            return .timeout
        case .userAbandoned:
            return .userAbandoned
        case .error:
            return .error
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
        await heartbeatTask.cancel()
        // The gateway persists the session (and enqueues the review job) only
        // when it receives an explicit `session.end` control frame. Closing the
        // socket without it leaves the session in a pending/active state.
        try? await transport.send(control: .sessionEnd(reason: "user"))
        await transport.disconnect()
        await activeSession.set(nil)
    }

    public func closeTransport() async {
        await transport.disconnect()
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
