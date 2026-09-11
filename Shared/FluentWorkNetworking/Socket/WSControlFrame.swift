import Foundation

/// Badge hit intensity tier, sent by the backend in `feedback.badge` frames.
///
/// Backend schema: `enum: ["soft", "highlight", "celebrate"]`.
/// Maps to the badge overlap score bucketed at the backend hit detector.
public enum FeedbackBadgeTier: String, Equatable, Sendable, Codable {
    case soft
    case highlight
    case celebrate
}

/// Wire-format control frames for the speaking-room WSS channel.
///
/// Keep field names aligned with the backend WSS contract tests
/// (`type` discriminator + snake_case payloads).
public enum WSControlFrame: Equatable, Sendable {
    case auth(ticket: String)
    case sessionReady(sessionID: String, userID: String?)
    case handshake(ticket: String, sessionID: String)
    case sessionStart(SessionStartPayload)
    case userSpeechStart
    case userSpeechEnd(text: String?, turnID: String?)
    /// I20 T-I20-1: client → gateway abort of an in-progress **recording** turn.
    ///
    /// Distinct from B15. B15's 70s cap (and `ai.turn.end outcome=timeout`) fire
    /// **after** `user.speech.end`, while waiting for collectTurn, and kill the
    /// session via `.failed("turn_timeout")`. This frame fires **during**
    /// `.recording` (no `user.speech.end` yet), keeps the session alive, and
    /// must not start collectTurn. `session_id` is connection-scoped and omitted
    /// — same as `user.speech.end`.
    case clientTurnAbort(turnID: String?, outcome: ClientTurnAbortOutcome)

    /// C→S abort outcomes. Subset of Core `TurnOutcome`: `ok` is never abort.
    public enum ClientTurnAbortOutcome: String, Equatable, Sendable, Codable {
        case timeout
        case userAbandoned = "user_abandoned"
        case error
    }
    /// B14: server → client ASR transcription relayed from the voice provider
    /// (e.g., Volcengine Duplex). This is the authoritative transcript for the
    /// current user turn, consistent with what the AI model heard.
    case clientASRTranscription(text: String, turnID: String?)
    /// Gateway → client incremental assistant text (v2).
    ///
    /// `serverTsMs` is the gateway's epoch-millisecond stamp at serialize time
    /// (P1-5). Optional on the wire — a v1 gateway omits it — and `nil` means
    /// *not measurable*, never *zero*: subtracting it from `Date()` without a
    /// clock offset measures the skew between the two machines, not the
    /// latency. See `ClockOffset`.
    case aiTextDelta(text: String, turnID: String?, serverTsMs: Int64?)
    case aiAudioChunk(sequence: UInt32)
    /// Gateway → client: warm the TTS decoder before binary audio messages.
    case aiTTSStart(turnID: String, voiceID: String, sampleRate: Int, codec: String)
    /// Gateway → client: terminate the TTS stream after the last binary audio message.
    case aiTTSEnd(turnID: String, completionStatus: String, durationMs: Int?)
    /// B15: explicit terminal status of a turn, mirroring backend voicepoc.TurnOutcome.
    /// B15-I3: log_id carries the vendor (Volcengine) trace identifier from the
    /// backend handshake, enabling iOS tracker events to be correlated with vendor logs.
    case aiTurnEnd(turnID: String?, outcome: TurnOutcome?, logID: String?)

    public enum TurnOutcome: String, Equatable, Sendable, Codable {
        /// Turn completed with a real AI response (response.done with content).
        case ok = "ok"
        /// Wait window expired but some progress was salvaged (ASR done, no TTS).
        case partial = "partial"
        /// Wait window expired with no progress; iOS should fall back to timeout UX.
        case timeout = "timeout"
        /// Provider sent an error event or recv failed.
        case error = "error"
    }
    case interrupt
    /// Client keepalive / server keepalive echo. `ts` mirrors the backend
    /// `voiceproto.Ping` field for diagnostics.
    case ping(ts: UInt64?)
    case pong(ts: UInt64?)
    case feedbackBadge(
        badge: String,
        phraseBlockID: String?,
        tier: FeedbackBadgeTier?,
        turnID: String?
    )
    case sessionEnd(reason: String?)
    /// Backend → client non-fatal error notice. Carries a stable machine code
    /// (e.g. `provider_audio_failed`, `provider_control_failed`,
    /// `client_asr_required`, `activate_failed`, `provider_open_failed`) plus a
    /// human-readable message. The transport mapper converts this into the
    /// `.failed` action so the session state machine degrades to `.failed`.
    case error(code: String, message: String?)

    /// What the session is about.
    ///
    /// **Every key here is the gateway's, not this file's invention.** Until
    /// 2026-09-12 this type sent `material_context` / `scene` / `voice_id`
    /// while `voiceproto.SessionStart` reads `material_id` / `scene_type` /
    /// `voice` — three fields, zero overlap, and `json.Unmarshal` ignores
    /// unknown keys without complaining. So the scene the app has been sending
    /// since it was written never reached the model, and
    /// `instructionsForSessionStart` has only ever emitted its fixed preamble.
    ///
    /// Nothing here enforces that the two sides agree; the backend's
    /// `voiceproto/frames.go` is the contract and this is a copy of it.
    /// `sessionStartPayloadKeysMatchTheGateway` in the test suite is what
    /// notices if the copy drifts again.
    ///
    /// **Not `Codable`, and that is not an oversight.** This type is never
    /// encoded on its own — `WSControlFrame`'s own `CodingKeys` is what writes
    /// the wire, and it is the only place the spellings live. This type used to
    /// carry a `CodingKeys` too, spelling the *old, wrong* names; changing it
    /// changed nothing on the wire, so it read as the contract while being
    /// unable to affect it. A second copy of a contract that silently does
    /// nothing is worse than no second copy.
    public struct SessionStartPayload: Equatable, Sendable {
        public var materialID: String?
        public var sceneType: String?
        public var voice: String?
        /// Continue a previous session instead of starting from nothing.
        ///
        /// An **id, not content**, and the server decides whether it may be
        /// read: the gateway resolves it through app-server, which compares
        /// owners and answers "not found" either way. The client cannot seed
        /// the provider's instructions with text of its own.
        public var continueFromSessionID: String?

        public init(
            materialID: String? = nil,
            sceneType: String? = nil,
            voice: String? = nil,
            continueFromSessionID: String? = nil
        ) {
            self.materialID = materialID
            self.sceneType = sceneType
            self.voice = voice
            self.continueFromSessionID = continueFromSessionID
        }
    }
}

public enum WSControlFrameCodingError: Error, Equatable, Sendable {
    case unknownType(String)
    case missingField(String)
}

extension WSControlFrame: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case ticket
        case sessionID = "session_id"
        case userID = "user_id"
        case text
        case sequence
        case turnID = "turn_id"
        case outcome // B15
        case logID = "log_id" // B15-I3
        case ts
        case badge
        case phraseBlockID = "phrase_block_id"
        case tier
        case reason
        case materialID = "material_id"
        case sceneType = "scene_type"
        // Two frames, two spellings, and both are the gateway's:
        // `session.start` reads `voice`, `ai.tts.start` reads `voice_id`.
        // Collapsing them into one key would break whichever frame lost.
        case voice
        case voiceID = "voice_id"
        case continueFromSessionID = "continue_from_session_id"
        case code
        case message
        case serverTsMs = "server_ts_ms"
        case sampleRate = "sample_rate"
        case codec
        case completionStatus = "completion_status"
        case durationMs = "duration_ms"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "auth":
            self = .auth(ticket: try container.decode(String.self, forKey: .ticket))

        case "session.ready":
            self = .sessionReady(
                sessionID: try container.decode(String.self, forKey: .sessionID),
                userID: try container.decodeIfPresent(String.self, forKey: .userID)
            )

        case "handshake":
            self = .handshake(
                ticket: try container.decode(String.self, forKey: .ticket),
                sessionID: try container.decode(String.self, forKey: .sessionID)
            )

        case "session.start":
            self = .sessionStart(
                .init(
                    materialID: try container.decodeIfPresent(String.self, forKey: .materialID),
                    sceneType: try container.decodeIfPresent(String.self, forKey: .sceneType),
                    voice: try container.decodeIfPresent(String.self, forKey: .voice),
                    continueFromSessionID: try container.decodeIfPresent(String.self, forKey: .continueFromSessionID)
                )
            )

        case "user.speech.start":
            self = .userSpeechStart

        case "user.speech.end":
            self = .userSpeechEnd(
                text: try container.decodeIfPresent(String.self, forKey: .text),
                turnID: try container.decodeIfPresent(String.self, forKey: .turnID)
            )

        case "client.turn.abort":
            self = .clientTurnAbort(
                turnID: try container.decodeIfPresent(String.self, forKey: .turnID),
                outcome: try container.decode(ClientTurnAbortOutcome.self, forKey: .outcome)
            )

        case "client.asr.transcription":
            self = .clientASRTranscription(
                text: try container.decode(String.self, forKey: .text),
                turnID: try container.decodeIfPresent(String.self, forKey: .turnID)
            )

        case "ai.text.delta":
            self = .aiTextDelta(
                text: try container.decode(String.self, forKey: .text),
                turnID: try container.decodeIfPresent(String.self, forKey: .turnID),
                serverTsMs: try container.decodeIfPresent(Int64.self, forKey: .serverTsMs)
            )

        case "ai.tts.start":
            self = .aiTTSStart(
                turnID: try container.decode(String.self, forKey: .turnID),
                voiceID: try container.decode(String.self, forKey: .voiceID),
                sampleRate: try container.decode(Int.self, forKey: .sampleRate),
                codec: try container.decode(String.self, forKey: .codec)
            )

        case "ai.tts.end":
            self = .aiTTSEnd(
                turnID: try container.decode(String.self, forKey: .turnID),
                completionStatus: try container.decode(String.self, forKey: .completionStatus),
                durationMs: try container.decodeIfPresent(Int.self, forKey: .durationMs)
            )

        case "ai.audio.chunk":
            self = .aiAudioChunk(sequence: try container.decode(UInt32.self, forKey: .sequence))

        case "ai.turn.end":
            let outcomeRaw = try container.decodeIfPresent(String.self, forKey: .outcome)
            self = .aiTurnEnd(
                turnID: try container.decodeIfPresent(String.self, forKey: .turnID),
                outcome: outcomeRaw.flatMap(TurnOutcome.init(rawValue:)),
                logID: try container.decodeIfPresent(String.self, forKey: .logID) // B15-I3
            )

        case "interrupt":
            self = .interrupt

        case "ping":
            self = .ping(ts: try container.decodeIfPresent(UInt64.self, forKey: .ts))

        case "pong":
            self = .pong(ts: try container.decodeIfPresent(UInt64.self, forKey: .ts))

        case "feedback.badge":
            self = .feedbackBadge(
                badge: try container.decode(String.self, forKey: .badge),
                phraseBlockID: try container.decodeIfPresent(String.self, forKey: .phraseBlockID),
                tier: try container.decodeIfPresent(FeedbackBadgeTier.self, forKey: .tier),
                turnID: try container.decodeIfPresent(String.self, forKey: .turnID)
            )

        case "session.end":
            self = .sessionEnd(reason: try container.decodeIfPresent(String.self, forKey: .reason))

        case "error":
            // Backend error notice (e.g. provider_audio_failed,
            // client_asr_required). `code` is required and stable so iOS can
            // branch on it; `message` is best-effort human text.
            self = .error(
                code: try container.decode(String.self, forKey: .code),
                message: try container.decodeIfPresent(String.self, forKey: .message)
            )

        default:
            throw WSControlFrameCodingError.unknownType(type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .auth(ticket):
            try container.encode("auth", forKey: .type)
            try container.encode(ticket, forKey: .ticket)

        case let .sessionReady(sessionID, userID):
            try container.encode("session.ready", forKey: .type)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encodeIfPresent(userID, forKey: .userID)

        case let .handshake(ticket, sessionID):
            try container.encode("handshake", forKey: .type)
            try container.encode(ticket, forKey: .ticket)
            try container.encode(sessionID, forKey: .sessionID)

        case let .sessionStart(payload):
            try container.encode("session.start", forKey: .type)
            try container.encodeIfPresent(payload.materialID, forKey: .materialID)
            try container.encodeIfPresent(payload.sceneType, forKey: .sceneType)
            try container.encodeIfPresent(payload.voice, forKey: .voice)
            try container.encodeIfPresent(payload.continueFromSessionID, forKey: .continueFromSessionID)

        case .userSpeechStart:
            try container.encode("user.speech.start", forKey: .type)

        case let .userSpeechEnd(text, turnID):
            try container.encode("user.speech.end", forKey: .type)
            try container.encodeIfPresent(text, forKey: .text)
            try container.encodeIfPresent(turnID, forKey: .turnID)

        case let .clientTurnAbort(turnID, outcome):
            try container.encode("client.turn.abort", forKey: .type)
            try container.encodeIfPresent(turnID, forKey: .turnID)
            try container.encode(outcome, forKey: .outcome)

        case let .clientASRTranscription(text, turnID):
            try container.encode("client.asr.transcription", forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(turnID, forKey: .turnID)

        case let .aiTextDelta(text, turnID, serverTsMs):
            try container.encode("ai.text.delta", forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(turnID, forKey: .turnID)
            try container.encodeIfPresent(serverTsMs, forKey: .serverTsMs)

        case let .aiTTSStart(turnID, voiceID, sampleRate, codec):
            try container.encode("ai.tts.start", forKey: .type)
            try container.encode(turnID, forKey: .turnID)
            try container.encode(voiceID, forKey: .voiceID)
            try container.encode(sampleRate, forKey: .sampleRate)
            try container.encode(codec, forKey: .codec)

        case let .aiTTSEnd(turnID, completionStatus, durationMs):
            try container.encode("ai.tts.end", forKey: .type)
            try container.encode(turnID, forKey: .turnID)
            try container.encode(completionStatus, forKey: .completionStatus)
            try container.encodeIfPresent(durationMs, forKey: .durationMs)

        case let .aiAudioChunk(sequence):
            try container.encode("ai.audio.chunk", forKey: .type)
            try container.encode(sequence, forKey: .sequence)

        case let .aiTurnEnd(turnID, outcome, logID):
            try container.encode("ai.turn.end", forKey: .type)
            try container.encodeIfPresent(turnID, forKey: .turnID)
            try container.encodeIfPresent(outcome, forKey: .outcome) // B15
            try container.encodeIfPresent(logID, forKey: .logID) // B15-I3

        case .interrupt:
            try container.encode("interrupt", forKey: .type)

        case let .ping(ts):
            try container.encode("ping", forKey: .type)
            try container.encodeIfPresent(ts, forKey: .ts)

        case let .pong(ts):
            try container.encode("pong", forKey: .type)
            try container.encodeIfPresent(ts, forKey: .ts)

        case let .feedbackBadge(badge, phraseBlockID, tier, turnID):
            try container.encode("feedback.badge", forKey: .type)
            try container.encode(badge, forKey: .badge)
            try container.encodeIfPresent(phraseBlockID, forKey: .phraseBlockID)
            try container.encodeIfPresent(tier, forKey: .tier)
            try container.encodeIfPresent(turnID, forKey: .turnID)

        case let .sessionEnd(reason):
            try container.encode("session.end", forKey: .type)
            try container.encodeIfPresent(reason, forKey: .reason)

        case let .error(code, message):
            try container.encode("error", forKey: .type)
            try container.encode(code, forKey: .code)
            try container.encodeIfPresent(message, forKey: .message)
        }
    }
}

public enum WSControlFrameCodec: Sendable {
    public static func encode(_ frame: WSControlFrame) throws -> Data {
        try JSONEncoder().encode(frame)
    }

    public static func decode(_ data: Data) throws -> WSControlFrame {
        try JSONDecoder().decode(WSControlFrame.self, from: data)
    }
}
