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
    /// B14: server → client ASR transcription relayed from the voice provider
    /// (e.g., Volcengine Duplex). This is the authoritative transcript for the
    /// current user turn, consistent with what the AI model heard.
    case clientASRTranscription(text: String, turnID: String?)
    case aiTextDelta(text: String)
    case aiAudioChunk(sequence: UInt32)
    /// B15: explicit terminal status of a turn, mirroring backend voicepoc.TurnOutcome.
    case aiTurnEnd(turnID: String?, outcome: TurnOutcome?)

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

    public struct SessionStartPayload: Equatable, Sendable, Codable {
        public var materialContext: String?
        public var scene: String?
        public var voiceID: String?

        public init(
            materialContext: String? = nil,
            scene: String? = nil,
            voiceID: String? = nil
        ) {
            self.materialContext = materialContext
            self.scene = scene
            self.voiceID = voiceID
        }

        enum CodingKeys: String, CodingKey {
            case materialContext = "material_context"
            case scene
            case voiceID = "voice_id"
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
        case ts
        case badge
        case phraseBlockID = "phrase_block_id"
        case tier
        case reason
        case materialContext = "material_context"
        case scene
        case voiceID = "voice_id"
        case code
        case message
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
                    materialContext: try container.decodeIfPresent(String.self, forKey: .materialContext),
                    scene: try container.decodeIfPresent(String.self, forKey: .scene),
                    voiceID: try container.decodeIfPresent(String.self, forKey: .voiceID)
                )
            )

        case "user.speech.start":
            self = .userSpeechStart

        case "user.speech.end":
            self = .userSpeechEnd(
                text: try container.decodeIfPresent(String.self, forKey: .text),
                turnID: try container.decodeIfPresent(String.self, forKey: .turnID)
            )

        case "client.asr.transcription":
            self = .clientASRTranscription(
                text: try container.decode(String.self, forKey: .text),
                turnID: try container.decodeIfPresent(String.self, forKey: .turnID)
            )

        case "ai.text.delta":
            self = .aiTextDelta(text: try container.decode(String.self, forKey: .text))

        case "ai.audio.chunk":
            self = .aiAudioChunk(sequence: try container.decode(UInt32.self, forKey: .sequence))

        case "ai.turn.end":
            self = .aiTurnEnd(
                turnID: try container.decodeIfPresent(String.self, forKey: .turnID),
                outcome: try container.decodeIfPresent(TurnOutcome.self, forKey: .outcome) // B15
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
            try container.encodeIfPresent(payload.materialContext, forKey: .materialContext)
            try container.encodeIfPresent(payload.scene, forKey: .scene)
            try container.encodeIfPresent(payload.voiceID, forKey: .voiceID)

        case .userSpeechStart:
            try container.encode("user.speech.start", forKey: .type)

        case let .userSpeechEnd(text, turnID):
            try container.encode("user.speech.end", forKey: .type)
            try container.encodeIfPresent(text, forKey: .text)
            try container.encodeIfPresent(turnID, forKey: .turnID)

        case let .clientASRTranscription(text, turnID):
            try container.encode("client.asr.transcription", forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(turnID, forKey: .turnID)

        case let .aiTextDelta(text):
            try container.encode("ai.text.delta", forKey: .type)
            try container.encode(text, forKey: .text)

        case let .aiAudioChunk(sequence):
            try container.encode("ai.audio.chunk", forKey: .type)
            try container.encode(sequence, forKey: .sequence)

        case let .aiTurnEnd(turnID, outcome):
            try container.encode("ai.turn.end", forKey: .type)
            try container.encodeIfPresent(turnID, forKey: .turnID)
            try container.encodeIfPresent(outcome, forKey: .outcome) // B15

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
