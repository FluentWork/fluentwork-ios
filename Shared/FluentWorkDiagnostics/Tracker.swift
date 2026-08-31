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

    // Queue-serialized instead of an actor: `TrackerClientProtocol.track` is a synchronous
    // requirement, so actor-isolated state cannot back it without changing the protocol.
    private let queue = DispatchQueue(label: "com.fluentwork.capturing-tracker")
    private var storage: [Event] = []

    public init() {}

    public var events: [Event] {
        queue.sync {
            storage
        }
    }

    public func track(event: String, properties: [String: String]) {
        queue.sync {
            storage.append(Event(name: event, properties: properties))
        }
    }
}
