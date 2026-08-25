import Foundation

public protocol ClockProtocol: Sendable {
    func now() -> Date
}

public protocol IDGeneratorProtocol: Sendable {
    func uuid() -> UUID
}

public struct SystemClock: ClockProtocol {
    public init() {}

    public func now() -> Date {
        Date()
    }
}

public struct SystemIDGenerator: IDGeneratorProtocol {
    public init() {}

    public func uuid() -> UUID {
        UUID()
    }
}

public struct FixedClock: ClockProtocol {
    public var date: Date

    public init(date: Date) {
        self.date = date
    }

    public func now() -> Date {
        date
    }
}

public struct FixedIDGenerator: IDGeneratorProtocol {
    public var value: UUID

    public init(value: UUID) {
        self.value = value
    }

    public func uuid() -> UUID {
        value
    }
}
