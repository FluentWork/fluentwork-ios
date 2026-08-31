import Foundation
import os

public enum LogDomain: String, Sendable, CaseIterable {
    case transport
    case api
    case session
    case audio
    case store
}

public protocol LoggingProtocol: Sendable {
    func debug(_ message: String, domain: LogDomain)
    func info(_ message: String, domain: LogDomain)
    func error(_ message: String, domain: LogDomain)
}

public struct OSLogLogger: LoggingProtocol {
    private let subsystem: String

    public init(subsystem: String = "com.fluentwork.app") {
        self.subsystem = subsystem
    }

    public func debug(_ message: String, domain: LogDomain) {
        #if DEBUG
        logger(for: domain).debug("\(message, privacy: .public)")
        #endif
    }

    public func info(_ message: String, domain: LogDomain) {
        logger(for: domain).info("\(message, privacy: .public)")
    }

    public func error(_ message: String, domain: LogDomain) {
        logger(for: domain).error("\(message, privacy: .public)")
    }

    private func logger(for domain: LogDomain) -> Logger {
        Logger(subsystem: subsystem, category: domain.rawValue)
    }
}

public final class CapturingLogger: LoggingProtocol, @unchecked Sendable {
    public struct Entry: Equatable, Sendable {
        public enum Level: String, Sendable {
            case debug
            case info
            case error
        }

        public let level: Level
        public let domain: LogDomain
        public let message: String
    }

    // Queue-serialized instead of an actor: `LoggingProtocol` is synchronous by design
    // (fire-and-forget logging from reducers/middleware), so isolated state cannot back it.
    private let queue = DispatchQueue(label: "com.fluentwork.capturing-logger")
    private var storage: [Entry] = []

    public init() {}

    public var entries: [Entry] {
        queue.sync {
            storage
        }
    }

    public func debug(_ message: String, domain: LogDomain) {
        append(.init(level: .debug, domain: domain, message: message))
    }

    public func info(_ message: String, domain: LogDomain) {
        append(.init(level: .info, domain: domain, message: message))
    }

    public func error(_ message: String, domain: LogDomain) {
        append(.init(level: .error, domain: domain, message: message))
    }

    private func append(_ entry: Entry) {
        queue.sync {
            storage.append(entry)
        }
    }
}
