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
        let deviceID = try tokens.deviceID()
        let accessToken = try await ensureAccessToken(deviceID: deviceID)
        let created = try await api.createSession(
            accessToken: accessToken,
            materialID: nil,
            sceneType: "demo"
        )
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

    public func submitTranscript(_ text: String) async {
        // Interrupt marker from SpeechSession middleware.
        guard text == "__interrupt__" else { return }
        await transport.markInterrupted()
        try? await transport.send(control: .interrupt)
    }

    public func sendSpeechBoundary(started: Bool, turnID: String?) async throws {
        if started {
            try await transport.send(control: .userSpeechStart)
        } else {
            // Backend uses turnID for badge hit dedupe. Schema accepts nil (server-side ASR path).
            try await transport.send(control: .userSpeechEnd(text: nil, turnID: turnID))
        }
    }

    public func sendAudioPCM(_ data: Data) async throws {
        try await transport.send(audio: data)
    }

    public func transportEvents() -> AsyncStream<SocketTransportEvent> {
        transport.events
    }

    public func sendDegradedTextMessage(_ text: String) async throws -> PostMessageResponse {
        let accessToken = try await requireAccessToken()
        let sessionID = try await requireActiveSessionID()
        return try await api.sendSessionMessage(
            sessionID: sessionID,
            accessToken: accessToken,
            text: text,
            channel: "text"
        )
    }

    public func pollReview(sessionID: String) async throws -> ReviewPollResponse {
        let accessToken = try await requireAccessToken()
        return try await api.getSessionReview(sessionID: sessionID, accessToken: accessToken)
    }

    public func mergeGuestAccount() async throws -> MergeResponse {
        let deviceID = try tokens.deviceID()
        let accessToken = try await requireAccessToken()
        return try await api.mergeGuestAccount(deviceID: deviceID, accessToken: accessToken)
    }

    public func endSession() async {
        await transport.disconnect()
        await activeSession.set(nil)
    }

    private func ensureAccessToken(deviceID: String) async throws -> String {
        if let existing = try tokens.accessToken(), !existing.isEmpty {
            return existing
        }
        let issued = try await api.issueGuest(deviceID: deviceID)
        try tokens.save(tokens: issued, deviceID: deviceID)
        return issued.accessToken
    }

    private func requireAccessToken() async throws -> String {
        let deviceID = try tokens.deviceID()
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
}
