import Foundation
import OSLog

/// Client ASR transcriber using Volcengine SDK.
///
/// This is a placeholder implementation that will be completed
/// once the Volcengine SDK is integrated (tracked in B14).
///
/// ## Integration Requirements
///
/// - Volcengine SDK dependency via SPM or CocoaPods
/// - API key configuration
/// - Network policy updates for Volcengine endpoints
///
/// ## Usage
///
/// ```swift
/// let transcriber = VolcengineClientASRTranscriber(
///     appID: "your-app-id",
///     token: "your-token"
/// )
/// let text = try await transcriber.transcribe(pcm: pcmStream)
/// ```
///
/// - Note: Current implementation throws `.notAvailable`.
///   Use `AppleSpeechClientASRTranscriber` as fallback.
public final class VolcengineClientASRTranscriber: ClientASRTranscriber {
    
    private let appID: String
    private let token: String
    private let logger = Logger(subsystem: "com.fluentwork.app", category: "VolcengineASR")
    
    /// Creates a new Volcengine ASR transcriber.
    ///
    /// - Parameters:
    ///   - appID: Volcengine application ID
    ///   - token: Volcengine authentication token
    public init(appID: String, token: String) {
        self.appID = appID
        self.token = token
        
        logger.info("VolcengineClientASRTranscriber initialized (placeholder)")
    }
    
    public func transcribe(pcm: AsyncStream<Data>) async throws -> String {
        // Consume the stream to avoid backpressure
        for await _ in pcm {
            // Discard PCM data
        }
        
        logger.warning("Volcengine SDK not yet integrated, throwing .notAvailable")
        
        // TODO(B14): Implement actual Volcengine SDK integration
        // 1. Initialize Volcengine ASR engine with appID + token
        // 2. Feed PCM audio chunks to engine
        // 3. Wait for final transcription result
        // 4. Return transcribed text
        
        throw ClientASRError.notAvailable
    }
}
