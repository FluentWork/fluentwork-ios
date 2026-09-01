import Foundation

/// Access token with expiration time
public struct AuthToken: Sendable, Equatable, Codable {
    public let value: String
    public let expiresAt: Date
    
    public init(value: String, expiresAt: Date) {
        self.value = value
        self.expiresAt = expiresAt
    }
    
    /// Check if token will expire within the given buffer time
    public func willExpire(within buffer: TimeInterval, now: Date = Date()) -> Bool {
        return expiresAt.timeIntervalSince(now) <= buffer
    }
    
    /// Check if token is already expired
    public func isExpired(now: Date = Date()) -> Bool {
        return expiresAt <= now
    }
}
