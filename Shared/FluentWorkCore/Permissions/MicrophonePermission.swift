import AVFoundation
import Foundation

/// Microphone permission helper for speech recording.
public enum MicrophonePermission {
    /// Request microphone permission from the user.
    /// - Returns: `true` if granted, `false` if denied.
    public static func request() async -> Bool {
        #if DEBUG
        // 替身开着就没有麦克风可授权：不碰系统权限，也不弹框。
        // 漏掉这一处，真机验证时仍然会弹麦克风权限、系统状态栏仍然显示在用麦 ——
        // 于是「用替身跑」和「用真麦跑」在观感上没区别。
        if MockDeviceMode.isMicrophoneMocked { return true }
        #endif
        #if os(iOS)
        // 显式 `return`：上面那道 `#if DEBUG` 让函数体不再是单表达式，
        // 隐式返回在这里不成立。
        return await withCheckedContinuation { continuation in
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
