import AVFoundation
import Foundation

/// Microphone permission helper for speech recording.
public enum MicrophonePermission {
    /// Request microphone permission from the user.
    /// - Returns: `true` if granted, `false` if denied.
    public static func request() async -> Bool {
        #if os(iOS)
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        #else
        // macOS doesn't use AVAudioSession
        return true
        #endif
    }

    /// Check if microphone permission is currently authorized.
    public static var isAuthorized: Bool {
        #if os(iOS)
        AVAudioSession.sharedInstance().recordPermission == .granted
        #else
        true
        #endif
    }

    /// Check if microphone permission is currently denied.
    public static var isDenied: Bool {
        #if os(iOS)
        AVAudioSession.sharedInstance().recordPermission == .denied
        #else
        false
        #endif
    }

    /// Check if microphone permission has not been determined yet.
    public static var isNotDetermined: Bool {
        #if os(iOS)
        AVAudioSession.sharedInstance().recordPermission == .undetermined
        #else
        false
        #endif
    }

    /// Get the current microphone permission status.
    #if os(iOS)
    public static var status: AVAudioSession.RecordPermission {
        AVAudioSession.sharedInstance().recordPermission
    }
    #endif
}
