import Foundation

/// Protocol for client-side automatic speech recognition (ASR) transcription.
///
/// Implementations convert PCM audio streams into text transcriptions on-device,
/// eliminating the need for server-side ASR and reducing latency.
///
/// ## Conforming Types
///
/// - `AppleSpeechClientASRTranscriber`: Uses Apple's Speech framework (iOS 17+)
/// - `VolcengineClientASRTranscriber`: Uses Volcengine SDK for ASR
///
/// ## Usage
///
/// ```swift
/// let transcriber = Container.shared.clientASRTranscriber()
/// let pcmStream = audioEngine.pcmAudioStream()
/// let text = try await transcriber.transcribe(pcm: pcmStream)
/// ```
public protocol ClientASRTranscriber: Sendable {
    /// Transcribe PCM audio data into text.
    ///
    /// - Parameter pcm: Async stream of PCM audio data (16-bit, 16kHz, mono)
    /// - Returns: Transcribed text in the configured language
    /// - Throws: `ClientASRError` if transcription fails
    ///
    /// - Note: Implementations should complete within 800ms to avoid blocking turn end.
    ///   If transcription takes longer, callers should timeout and send `nil` text.
    func transcribe(pcm: AsyncStream<Data>) async throws -> String
}

/// Errors that can occur during client-side ASR transcription.
public enum ClientASRError: Error, Sendable {
    /// ASR engine is not available on this device
    case notAvailable
    
    /// Transcription timed out
    case timeout
    
    /// Audio format is not supported
    case unsupportedFormat
    
    /// ASR engine reported an error
    case engineError(String)
    
    /// Authorization denied (e.g., microphone or speech recognition permission)
    case authorizationDenied
}

extension ClientASRError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "Client ASR is not available on this device"
        case .timeout:
            return "Client ASR transcription timed out"
        case .unsupportedFormat:
            return "Audio format is not supported for client ASR"
        case .engineError(let message):
            return "Client ASR engine error: \(message)"
        case .authorizationDenied:
            return "Speech recognition authorization denied"
        }
    }
}
