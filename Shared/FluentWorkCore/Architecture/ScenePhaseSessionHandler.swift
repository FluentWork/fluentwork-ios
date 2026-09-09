import Foundation

public enum ScenePhaseKind: Sendable {
    case background
    case active
    case inactive
    case unknown
}

public enum ScenePhaseSessionHandler: Sendable {
    public static func event(
        scenePhase: ScenePhaseKind,
        sessionPhase: SpeechSessionPhase
    ) -> SpeechSessionEvent? {
        switch scenePhase {
        case .background:
            return sessionPhase.isActive ? .forceClose : nil
        case .active:
            return sessionPhase == .failed ? .reconnectTimedOut : nil
        case .inactive, .unknown:
            return nil
        }
    }
}
