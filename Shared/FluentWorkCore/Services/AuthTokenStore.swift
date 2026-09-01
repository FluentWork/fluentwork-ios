import FluentWorkNetworking
import Foundation

public enum AuthTokenStoreKey {
    public static let accessToken = "auth.access_token"
    public static let refreshToken = "auth.refresh_token"
    public static let userID = "auth.user_id"
    public static let deviceID = "auth.device_id"
    public static let isGuest = "auth.is_guest"
}

/// Persists guest/registered tokens for Session API bearer calls.
public protocol AuthTokenStoreProtocol: Sendable {
    func deviceID() throws -> String
    func accessToken() throws -> String?
    func save(tokens: TokenResponse, deviceID: String) throws
    func clear() throws
    
    /// Extracts user ID from stored token (optional, for convenience).
    func userID() throws -> String?
    
    /// Checks if current user is a guest (optional, for convenience).
    func isGuest() throws -> Bool
}

public struct SecureAuthTokenStore: AuthTokenStoreProtocol {
    private let storage: SecureStorageProtocol
    private let idGenerator: IDGeneratorProtocol

    public init(storage: SecureStorageProtocol, idGenerator: IDGeneratorProtocol) {
        self.storage = storage
        self.idGenerator = idGenerator
    }

    public func deviceID() throws -> String {
        if let data = try storage.read(key: AuthTokenStoreKey.deviceID),
           let existing = String(data: data, encoding: .utf8),
           !existing.isEmpty
        {
            return existing
        }
        let created = idGenerator.uuid().uuidString
        try storage.write(Data(created.utf8), key: AuthTokenStoreKey.deviceID)
        return created
    }

    public func accessToken() throws -> String? {
        guard let data = try storage.read(key: AuthTokenStoreKey.accessToken) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func save(tokens: TokenResponse, deviceID: String) throws {
        try storage.write(Data(tokens.accessToken.utf8), key: AuthTokenStoreKey.accessToken)
        try storage.write(Data(tokens.refreshToken.utf8), key: AuthTokenStoreKey.refreshToken)
        try storage.write(Data(tokens.userID.utf8), key: AuthTokenStoreKey.userID)
        try storage.write(Data(deviceID.utf8), key: AuthTokenStoreKey.deviceID)
        try storage.write(Data((tokens.isGuest ? "1" : "0").utf8), key: AuthTokenStoreKey.isGuest)
    }

    public func clear() throws {
        try storage.delete(key: AuthTokenStoreKey.accessToken)
        try storage.delete(key: AuthTokenStoreKey.refreshToken)
        try storage.delete(key: AuthTokenStoreKey.userID)
        try storage.delete(key: AuthTokenStoreKey.isGuest)
    }

    public func userID() throws -> String? {
        guard let data = try storage.read(key: AuthTokenStoreKey.userID) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func isGuest() throws -> Bool {
        guard let data = try storage.read(key: AuthTokenStoreKey.isGuest),
              let value = String(data: data, encoding: .utf8)
        else {
            // Default to true (guest) when unknown, matching pre-registration behavior.
            return true
        }
        return value == "1"
    }
}
