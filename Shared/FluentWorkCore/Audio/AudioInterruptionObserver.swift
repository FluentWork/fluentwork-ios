@preconcurrency import AVFoundation
import Dispatch
import Foundation

public enum AudioInterruptionKind: Equatable, Sendable {
    case began
    case ended(shouldResume: Bool)
    case routeChanged(reason: String)
}

public protocol AudioInterruptionObserving: Sendable {
    func start(_ onEvent: @escaping @Sendable (AudioInterruptionKind) async -> Void)
    func stop()
}

public final class AudioInterruptionObserver: AudioInterruptionObserving, @unchecked Sendable {
    public static var interruptionNotification: Notification.Name {
        #if os(iOS)
        AVAudioSession.interruptionNotification
        #else
        Notification.Name("FluentWork.test.audio.interruption")
        #endif
    }

    public static var routeChangeNotification: Notification.Name {
        #if os(iOS)
        AVAudioSession.routeChangeNotification
        #else
        Notification.Name("FluentWork.test.audio.routeChange")
        #endif
    }

    public static var interruptionTypeKey: String {
        #if os(iOS)
        AVAudioSessionInterruptionTypeKey
        #else
        "AVAudioSessionInterruptionTypeKey"
        #endif
    }

    public static var interruptionOptionKey: String {
        #if os(iOS)
        AVAudioSessionInterruptionOptionKey
        #else
        "AVAudioSessionInterruptionOptionKey"
        #endif
    }

    public static var routeChangeReasonKey: String {
        #if os(iOS)
        AVAudioSessionRouteChangeReasonKey
        #else
        "AVAudioSessionRouteChangeReasonKey"
        #endif
    }

    /// Matches `AVAudioSession.InterruptionType.began.rawValue`.
    public static let interruptionBeganRaw: UInt = 1
    /// Matches `AVAudioSession.InterruptionType.ended.rawValue`.
    public static let interruptionEndedRaw: UInt = 0
    /// Matches `AVAudioSession.InterruptionOptions.shouldResume.rawValue`.
    public static let shouldResumeOptionRaw: UInt = 1
    /// Matches `AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue`.
    public static let routeNewDeviceAvailableRaw: UInt = 1
    /// Matches `AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue`.
    public static let routeOldDeviceUnavailableRaw: UInt = 2
    /// Matches `AVAudioSession.RouteChangeReason.categoryChange.rawValue`.
    public static let routeCategoryChangeRaw: UInt = 3

    private let sessionQueue = DispatchQueue(label: "com.fluentwork.audio-interruption-observer")
    private var observers: [NSObjectProtocol] = []
    private let center: NotificationCenter

    public init(center: NotificationCenter = .default) {
        self.center = center
    }

    deinit {
        stop()
    }

    public func start(_ onEvent: @escaping @Sendable (AudioInterruptionKind) async -> Void) {
        stop()
        sessionQueue.sync {
            let interruption = center.addObserver(
                forName: Self.interruptionNotification,
                object: nil,
                queue: nil
            ) { notification in
                guard let kind = Self.interruptionKind(from: notification) else { return }
                Task {
                    await onEvent(kind)
                }
            }
            observers.append(interruption)

            let route = center.addObserver(
                forName: Self.routeChangeNotification,
                object: nil,
                queue: nil
            ) { notification in
                guard let kind = Self.routeKind(from: notification) else { return }
                Task {
                    await onEvent(kind)
                }
            }
            observers.append(route)
        }
    }

    public func stop() {
        sessionQueue.sync {
            for token in observers {
                center.removeObserver(token)
            }
            observers.removeAll()
        }
    }

    private static func uintValue(in info: [AnyHashable: Any], key: String) -> UInt? {
        if let value = info[key] as? UInt {
            return value
        }
        if let value = info[key] as? Int {
            return UInt(value)
        }
        if let value = info[key] as? NSNumber {
            return value.uintValue
        }
        return nil
    }

    static func interruptionKind(from notification: Notification) -> AudioInterruptionKind? {
        guard let info = notification.userInfo,
              let typeRaw = uintValue(in: info, key: interruptionTypeKey)
        else {
            return nil
        }

        switch typeRaw {
        case interruptionBeganRaw:
            return .began
        case interruptionEndedRaw:
            let optionsRaw = uintValue(in: info, key: interruptionOptionKey) ?? 0
            return .ended(shouldResume: optionsRaw & shouldResumeOptionRaw != 0)
        default:
            return nil
        }
    }

    static func routeKind(from notification: Notification) -> AudioInterruptionKind? {
        guard let info = notification.userInfo,
              let reasonRaw = uintValue(in: info, key: routeChangeReasonKey)
        else {
            return nil
        }

        switch reasonRaw {
        case routeOldDeviceUnavailableRaw:
            return .routeChanged(reason: "oldDeviceUnavailable")
        case routeNewDeviceAvailableRaw:
            return .routeChanged(reason: "newDeviceAvailable")
        case routeCategoryChangeRaw:
            return .routeChanged(reason: "categoryChange")
        default:
            return nil
        }
    }
}
