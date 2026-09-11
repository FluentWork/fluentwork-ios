import FluentWorkNetworking
import Foundation

/// A `TTSDecoder` that actually plays what it is fed.
///
/// `MockTTSDecoder` records and discards — which is fine for the tests it was
/// written for and fatal for the path it is bound to in production, because
/// `TTSFrameDispatcher` only claims binary frames once it has seen an
/// `ai.tts.start`, and today's gateway never sends one. That accident is the
/// only reason audio still works: every frame misses the dispatcher and falls
/// through to `audioEngine.play(frame:)`. The moment the gateway starts sending
/// `ai.tts.start` — which is what gives frames a **turn**, and therefore what
/// makes an interrupted turn's in-flight audio droppable — the audio would be
/// routed here instead, and a recorder makes no sound.
///
/// ## Why this bridges through a stream instead of spawning a `Task` per frame
///
/// `TTSDecoder.feed` is **synchronous** and playback is `async`, so the two
/// cannot be joined directly. The obvious bridge is a `Task` per frame, and it
/// is wrong: it hands frames to the executor in whatever order it chooses, and
/// **order is the entire semantics of a stream**. Frames are therefore queued in
/// call order and drained by a single consumer.
///
/// The ordering invariant is what `engineBackedDecoderPlaysInTheOrderItWasFed`
/// pins. It is also the one thing a per-frame `Task` would break *silently* —
/// out-of-order audio is still audio, it just sounds wrong.
public final class EngineBackedTTSDecoder: TTSDecoder, @unchecked Sendable {
    /// Where a decoded frame goes. Injected rather than taking an
    /// `AudioEngineProtocol` so the ordering can be tested without an engine —
    /// and so this type stays honest about doing nothing but sequencing.
    public typealias Player = @Sendable (WSAudioFrame) async -> Void

    private let queue = DispatchQueue(label: "com.fluentwork.engine-tts-decoder")
    private let player: Player
    private var frames: AsyncStream<WSAudioFrame>.Continuation?
    private var consumer: Task<Void, Never>?

    public init(player: @escaping Player) {
        self.player = player

        let pair = AsyncStream<WSAudioFrame>.makeStream()
        self.frames = pair.continuation
        // One consumer for the life of the decoder, started here rather than on
        // the first `prepare` so there is no window in which a frame is queued
        // with nobody draining it. It ends when the decoder is released, which
        // is when the dispatcher that owns it is released.
        self.consumer = Task { [player] in
            for await frame in pair.stream {
                await player(frame)
            }
        }
    }

    deinit {
        frames?.finish()
        consumer?.cancel()
    }

    public func prepare(voiceId: String, sampleRate: Int, codec: String) throws {
        // Same validation as the mock, deliberately: the dispatcher calls this
        // before it starts claiming frames, and a codec this path cannot carry
        // must fail there rather than be swallowed here.
        guard TTSCodec(rawValue: codec) != nil else {
            throw TTSDecoderError.unsupportedCodec(codec)
        }
        guard [16_000, 24_000, 48_000].contains(sampleRate) else {
            throw TTSDecoderError.unsupportedSampleRate(sampleRate)
        }
    }

    public func feed(seq: UInt32, bytes: Data, turnId: String) throws {
        guard !bytes.isEmpty else {
            throw TTSDecoderError.emptyPayload
        }
        // Queued, not played. `player` runs on the consumer, in this order.
        frames?.yield(WSAudioFrame(sequence: seq, opusPayload: bytes))
    }

    public func finish(turnId: String, status: String, durationMs: Int?) throws {
        // Nothing to do, and that is deliberate rather than unfinished: the
        // frames already queued belong to the turn that is ending and must
        // still be played (that is what "the user heard it" means), so ending a
        // stream is not a reason to drop them. Discarding is the dispatcher's
        // `.draining` job, which happens before anything reaches this type.
    }
}
