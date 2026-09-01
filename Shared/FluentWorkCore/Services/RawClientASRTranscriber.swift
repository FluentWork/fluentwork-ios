import Foundation

/// Debug-only client ASR transcriber that returns empty strings.
///
/// This implementation is useful for testing the client ASR pipeline
/// without requiring actual ASR capabilities.
///
/// ## Usage
///
/// ```swift
/// #if DEBUG
/// container.clientASRTranscriber.register {
///     RawClientASRTranscriber()
/// }
/// #endif
/// ```
public struct RawClientASRTranscriber: ClientASRTranscriber {
    
    public init() {}
    
    public func transcribe(pcm: AsyncStream<Data>) async throws -> String {
        // Consume the stream to avoid backpressure
        for await _ in pcm {
            // Discard PCM data
        }
        
        // Return empty string (simulates ASR unavailable scenario)
        return ""
    }
}
