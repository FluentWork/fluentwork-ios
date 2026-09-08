@preconcurrency import AVFoundation
import Dispatch
import Foundation

public protocol AudioSessionManaging: Sendable {
    func configure(for route: AudioRoute) throws
    func pause() throws
    func resume() throws
    var isActive: Bool { get async }
}

public enum AudioRoute: Sendable {
    case capture
    case playback
    case fullDuplex
}

public final class DefaultAudioSessionManager: AudioSessionManaging, @unchecked Sendable {
    private let sessionQueue = DispatchQueue(
        label: "com.fluentwork.audio-session-manager"
    )
    private var active = false

    public init() {}

    public func configure(for route: AudioRoute) throws {
        #if os(iOS)
        try sessionQueue.sync {
            let session = AVAudioSession.sharedInstance()
            switch route {
            case .capture:
                try session.setCategory(
                    .record,
                    mode: .measurement,
                    options: [.allowBluetoothHFP]
                )
            case .playback:
                try session.setCategory(.playback, mode: .spokenAudio)
            case .fullDuplex:
                try session.setCategory(
                    .playAndRecord,
                    mode: .voiceChat,
                    options: [.defaultToSpeaker, .allowBluetoothHFP]
                )
            }

            try session.setPreferredSampleRate(16_000)
            try session.setPreferredIOBufferDuration(0.02)
            do {
                try session.setActive(true)
            } catch {
                throw AudioEngineError.audioSessionConflict(
                    "Audio session could not be activated. Please close other apps using audio (e.g., music, video) and try again. Underlying error: \(error.localizedDescription)"
                )
            }
            active = true
        }
        #else
        sessionQueue.sync { active = true }
        #endif
    }

    public func pause() throws {
        #if os(iOS)
        try sessionQueue.sync {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
            active = false
        }
        #else
        sessionQueue.sync { active = false }
        #endif
    }

    public func resume() throws {
        #if os(iOS)
        try sessionQueue.sync {
            try AVAudioSession.sharedInstance().setActive(true)
            active = true
        }
        #else
        sessionQueue.sync { active = true }
        #endif
    }

    public var isActive: Bool {
        get async {
            sessionQueue.sync { active }
        }
    }
}
