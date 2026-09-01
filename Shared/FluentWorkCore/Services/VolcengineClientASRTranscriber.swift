import Foundation

/// B13 — placeholder `ClientASRTranscriber` backed by the Volcengine RTC SDK.
///
/// This is a stub until B14+ lands the Volcengine SDK integration. It throws
/// `VolcengineNotAvailableError` for every call so callers fall through to the
/// `clientASRFailed(reason: .notAvailable)` path without any logging noise.
///
/// To upgrade to the real implementation:
///   1. Add the Volcengine SDK to `Package.swift` dependencies.
///   2. Replace the body of `transcribe` with the actual SDK call pattern.
///   3. Map SDK callbacks → `AudioEngineEvent.clientASRCompleted` / `.clientASRFailed`.
///   4. Add `logger.debug` / `.info` / `.error` calls mirroring
///      `AppleSpeechClientASRTranscriber` (same levels, same domain `.clientASR`).
public struct VolcengineClientASRTranscriber: ClientASRTranscriber {
    public enum VolcengineNotAvailableError: Error, Sendable {
        case notYetIntegrated
    }

    public init() {}

    public var isAvailable: Bool { false }

    public func startRecognition(
        audioSession: AVAudioSession,
        onResult: @escaping @Sendable (Bool, String?) -> Void,
        onFailure: @escaping @Sendable (ClientASRFailureReason) -> Void
    ) {
        onFailure(.notAvailable)
    }

    public func cancel() {}
}
