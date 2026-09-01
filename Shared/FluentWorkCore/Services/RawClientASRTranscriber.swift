import AVFoundation
import Foundation

/// B13 — debug `ClientASRTranscriber` that immediately returns an empty string.
///
/// Use this in development / smoke tests when you want the ASR slot to fire
/// without any real transcription work. Produces no side effects and is safe
/// to use in automated tests.
public struct RawClientASRTranscriber: ClientASRTranscriber {
    public init() {}

    public var isAvailable: Bool { true }

    public func startRecognition(
        audioSession: AVAudioSession,
        onResult: @escaping @Sendable (Bool, String?) -> Void,
        onFailure: @escaping @Sendable (ClientASRFailureReason) -> Void
    ) {
        // Synchronously deliver a final empty transcript so the caller's
        // async continuation is satisfied without any real audio processing.
        onResult(true, "")
    }

    public func cancel() {}
}
