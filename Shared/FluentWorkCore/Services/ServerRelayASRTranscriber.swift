import Foundation
import OSLog

/// No-op ASR transcriber for the B14 server-relay architecture.
///
/// In the B14 architecture, the voice gateway (backend) holds the Volcengine
/// Doubao credentials and performs real-time ASR as part of its duplex WSS session.
/// The resulting transcription is relayed back to the iOS client via the
/// `client.asr.transcription` WSS frame and dispatched directly to the Redux store.
///
/// This transcriber therefore returns an empty string immediately — it is present
/// only to satisfy the `ClientASRTranscriber` protocol so the dependency container
/// can remain polymorphic.
///
/// ## Fallback
///
/// To run local Apple Speech instead (e.g., when the voice gateway lacks Volcengine
/// credentials), register a different implementation at startup:
///
/// ```swift
/// container.clientASRTranscriber.register { AppleSpeechClientASRTranscriber() }
/// ```
public final class ServerRelayASRTranscriber: ClientASRTranscriber {
    private let logger = Logger(subsystem: "com.fluentwork.app", category: "ServerRelayASR")

    public init() {
        logger.info("ServerRelayASRTranscriber initialized — ASR is relayed from voice gateway via WSS")
    }

    /// Returns an empty string immediately.
    ///
    /// Transcription is supplied by the voice gateway through the
    /// `client.asr.transcription` WSS frame and consumed by
    /// `SpeechSessionMiddleware` without going through this protocol.
    public func transcribe(pcm: AsyncStream<Data>) async throws -> String {
        // Drain the PCM stream to avoid backpressure, then return empty.
        // The actual transcription comes from the server via WSS relay.
        for await _ in pcm {
            // Discard PCM data — ASR is handled server-side.
        }
        return ""
    }
}
