import Foundation
import FluentWorkNetworking

/// Streaming TTS decoder contract used by WSS V2 `ai.tts.*` frames.
///
/// Binary audio messages do not repeat `turn_id`; `TTSFrameDispatcher`
/// associates each `WSAudioFrame` with the active `ai.tts.start`.
public protocol TTSDecoder: Sendable {
    func prepare(voiceId: String, sampleRate: Int, codec: String) throws
    func feed(seq: UInt32, bytes: Data, turnId: String) throws
    func finish(turnId: String, status: String, durationMs: Int?) throws
}

public enum TTSCodec: String, Sendable {
    case opus
    case pcm
}

public enum TTSCompletionStatus: String, Sendable {
    case ok
    case interrupted
    case error
}

public enum TTSDecoderError: Error, Equatable, Sendable {
    case unsupportedCodec(String)
    case unsupportedSampleRate(Int)
    case emptyPayload
}

/// Routes control and binary TTS frames to a `TTSDecoder`.
///
/// `ai.tts.audio` is a WebSocket binary message decoded by `WSAudioFrameCodec`,
/// not a JSON control frame.
///
/// The dispatcher is middleware-scoped and outlives a single speaking-room
/// session. Call `reset()` from session teardown so a leftover `ai.tts.start`
/// cannot swallow the next session's legacy PCM. After barge-in `interrupt()`,
/// leftover binary frames stay consumed (not played as PCM) until `ai.tts.end`.
public final class TTSFrameDispatcher: @unchecked Sendable {
    private enum Stream {
        case idle
        case active(String)
        case draining(String)
    }

    private let queue = DispatchQueue(label: "com.fluentwork.tts-frame-dispatcher")
    private let decoder: any TTSDecoder
    private var stream: Stream = .idle

    public init(decoder: any TTSDecoder) {
        self.decoder = decoder
    }

    public func handle(control frame: WSControlFrame) throws {
        switch frame {
        case let .aiTTSStart(turnID, voiceID, sampleRate, codec):
            try queue.sync {
                if case let .active(previousTurnID) = stream {
                    try decoder.finish(
                        turnId: previousTurnID,
                        status: TTSCompletionStatus.interrupted.rawValue,
                        durationMs: nil
                    )
                }
                try decoder.prepare(
                    voiceId: voiceID,
                    sampleRate: sampleRate,
                    codec: codec
                )
                stream = .active(turnID)
            }

        case let .aiTTSEnd(turnID, completionStatus, durationMs):
            try queue.sync {
                switch stream {
                case .idle:
                    return
                case .active:
                    try decoder.finish(
                        turnId: turnID,
                        status: completionStatus,
                        durationMs: durationMs
                    )
                    stream = .idle
                case .draining:
                    // Already finished on interrupt; wait for end so leftover
                    // binary frames are not handed to the PCM player.
                    stream = .idle
                }
            }

        default:
            break
        }
    }

    @discardableResult
    public func handle(audio frame: WSAudioFrame) throws -> Bool {
        try queue.sync {
            switch stream {
            case .idle:
                return false
            case .draining:
                return true
            case let .active(turnID):
                guard !frame.opusPayload.isEmpty else {
                    throw TTSDecoderError.emptyPayload
                }
                try decoder.feed(
                    seq: frame.sequence,
                    bytes: frame.opusPayload,
                    turnId: turnID
                )
                return true
            }
        }
    }

    public func interrupt() throws {
        try queue.sync {
            guard case let .active(turnID) = stream else { return }
            try decoder.finish(
                turnId: turnID,
                status: TTSCompletionStatus.interrupted.rawValue,
                durationMs: nil
            )
            stream = .draining(turnID)
        }
    }

    /// Clears any in-flight TTS stream. Safe to call when idle.
    public func reset() throws {
        try queue.sync {
            if case let .active(turnID) = stream {
                try decoder.finish(
                    turnId: turnID,
                    status: TTSCompletionStatus.interrupted.rawValue,
                    durationMs: nil
                )
            }
            stream = .idle
        }
    }
}
