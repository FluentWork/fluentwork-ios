import FluentWorkNetworking
import Foundation

extension SpeakingRoomAction {
    /// Bridges transport-level events into speaking-room actions for Store dispatch.
    public init?(_ transportAction: SpeakingRoomTransportAction) {
        switch transportAction {
        case .socketReady:
            self = .session(.socketReady)
        case let .badgeHit(badge):
            self = .badgeHit(badge)
        case let .failed(message):
            self = .session(.failed(message))
        case .networkDowngraded:
            self = .session(.networkLost)
        }
    }
}
