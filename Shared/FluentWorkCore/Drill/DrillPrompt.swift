import Foundation
import FluentWorkNetworking

public struct DrillPrompt: Equatable, Sendable, Identifiable {
    public let blockID: String
    public let intentZH: String

    public var id: String { blockID }

    public init(blockID: String, intentZH: String) {
        self.blockID = blockID
        self.intentZH = intentZH
    }

    public init(card: DrillCard) {
        self.init(blockID: card.blockID, intentZH: card.intentZH)
    }
}
