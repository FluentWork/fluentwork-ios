import FluentWorkNetworking
import Foundation

extension SpeakingRoomAction {
    /// Bridges transport-level events into speaking-room actions for Store dispatch.
    public init?(_ transportAction: SpeakingRoomTransportAction) {
        switch transportAction {
        case .socketReady:
            self = .socketReady
        case let .badgeHit(badge):
            self = .badgeHit(badge)
        case let .failed(message):
            self = .failed(message)
        case .networkDowngraded:
            self = .networkDowngraded
        }
    }
}
