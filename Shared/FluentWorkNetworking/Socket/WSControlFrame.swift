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
    case aiTextDelta(text: String)
    case aiAudioChunk(sequence: UInt32)
    case aiTurnEnd(turnID: String?)
    case interrupt
    case feedbackBadge(badge: String, phraseBlockID: String?, tier: FeedbackBadgeTier?)
    case sessionEnd(reason: String?)

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
        case badge
        case phraseBlockID = "phrase_block_id"
        case tier
        case reason
        case materialContext = "material_context"
        case scene
        case voiceID = "voice_id"
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

        case "ai.text.delta":
            self = .aiTextDelta(text: try container.decode(String.self, forKey: .text))

        case "ai.audio.chunk":
            self = .aiAudioChunk(sequence: try container.decode(UInt32.self, forKey: .sequence))

        case "ai.turn.end":
            self = .aiTurnEnd(turnID: try container.decodeIfPresent(String.self, forKey: .turnID))

        case "interrupt":
            self = .interrupt

        case "feedback.badge":
            self = .feedbackBadge(
                badge: try container.decode(String.self, forKey: .badge),
                phraseBlockID: try container.decodeIfPresent(String.self, forKey: .phraseBlockID),
                tier: try container.decodeIfPresent(FeedbackBadgeTier.self, forKey: .tier)
            )

        case "session.end":
            self = .sessionEnd(reason: try container.decodeIfPresent(String.self, forKey: .reason))

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

        case let .aiTextDelta(text):
            try container.encode("ai.text.delta", forKey: .type)
            try container.encode(text, forKey: .text)

        case let .aiAudioChunk(sequence):
            try container.encode("ai.audio.chunk", forKey: .type)
            try container.encode(sequence, forKey: .sequence)

        case let .aiTurnEnd(turnID):
            try container.encode("ai.turn.end", forKey: .type)
            try container.encodeIfPresent(turnID, forKey: .turnID)

        case .interrupt:
            try container.encode("interrupt", forKey: .type)

        case let .feedbackBadge(badge, phraseBlockID, tier):
            try container.encode("feedback.badge", forKey: .type)
            try container.encode(badge, forKey: .badge)
            try container.encodeIfPresent(phraseBlockID, forKey: .phraseBlockID)
            try container.encodeIfPresent(tier, forKey: .tier)

        case let .sessionEnd(reason):
            try container.encode("session.end", forKey: .type)
            try container.encodeIfPresent(reason, forKey: .reason)
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
