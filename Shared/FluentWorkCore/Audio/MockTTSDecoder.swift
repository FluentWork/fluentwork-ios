import Dispatch
import Foundation

/// Records TTS decoder calls for unit tests and the V2 protocol empty-run.
///
/// This is a placeholder until ADR-0073's system Opus decoder lands. It does
/// not decode audio or drive `AVAudioEngine`.
public final class MockTTSDecoder: TTSDecoder, @unchecked Sendable {
    public private(set) var prepares: [(voiceId: String, sampleRate: Int, codec: String)] = []
    public private(set) var feeds: [(seq: UInt32, bytes: Data, turnId: String)] = []
    public private(set) var finishes: [(turnId: String, status: String, durationMs: Int?)] = []

    private let queue = DispatchQueue(label: "com.fluentwork.mock-tts-decoder")

    public init() {}

    public func prepare(voiceId: String, sampleRate: Int, codec: String) throws {
        try queue.sync {
            guard TTSCodec(rawValue: codec) != nil else {
                throw TTSDecoderError.unsupportedCodec(codec)
            }
            guard [16_000, 24_000, 48_000].contains(sampleRate) else {
                throw TTSDecoderError.unsupportedSampleRate(sampleRate)
            }
            prepares.append((voiceId, sampleRate, codec))
        }
    }

    public func feed(seq: UInt32, bytes: Data, turnId: String) throws {
        try queue.sync {
            guard !bytes.isEmpty else {
                throw TTSDecoderError.emptyPayload
            }
            feeds.append((seq, bytes, turnId))
        }
    }

    public func finish(turnId: String, status: String, durationMs: Int?) throws {
        queue.sync {
            finishes.append((turnId, status, durationMs))
        }
    }

    public func snapshotPrepares() -> [(voiceId: String, sampleRate: Int, codec: String)] {
        queue.sync { prepares }
    }

    public func snapshotFeeds() -> [(seq: UInt32, bytes: Data, turnId: String)] {
        queue.sync { feeds }
    }

    public func snapshotFinishes() -> [(turnId: String, status: String, durationMs: Int?)] {
        queue.sync { finishes }
    }
}
