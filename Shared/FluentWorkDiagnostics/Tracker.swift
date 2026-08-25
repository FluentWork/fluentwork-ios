import Foundation

public protocol TrackerClientProtocol: Sendable {
    func track(event: String, properties: [String: String])
}

public struct ConsoleTracker: TrackerClientProtocol {
    public init() {}

    public func track(event: String, properties: [String: String]) {
        #if DEBUG
        print("[Tracker] \(event) \(properties)")
        #endif
    }
}

public final class CapturingTracker: TrackerClientProtocol, @unchecked Sendable {
    public struct Event: Equatable, Sendable {
        public let name: String
        public let properties: [String: String]

        public init(name: String, properties: [String: String]) {
            self.name = name
            self.properties = properties
        }
    }

    private let lock = NSLock()
    private var _events: [Event] = []

    public init() {}

    public var events: [Event] {
        lock.lock()
        defer { lock.unlock() }
        return _events
    }

    public func track(event: String, properties: [String: String]) {
        lock.lock()
        _events.append(Event(name: event, properties: properties))
        lock.unlock()
    }
}
