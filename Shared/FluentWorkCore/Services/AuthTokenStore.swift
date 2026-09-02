import FluentWorkNetworking
import Foundation

public enum AuthTokenStoreKey {
    public static let accessToken = "auth.access_token"
    public static let accessTokenExpiresAt = "auth.access_token_expires_at"
    public static let refreshToken = "auth.refresh_token"
    public static let userID = "auth.user_id"
    public static let deviceID = "auth.device_id"
    public static let isGuest = "auth.is_guest"
}

/// Persists guest/registered tokens for Session API bearer calls.
///
/// All operations are `async throws` because both production (`SecureAuthTokenStore`)
/// and test (`InMemoryAuthTokenStore`) backed stores serialize over Keychain IPC or an
/// actor's isolated state, respectively. Synchronous throws would force these calls
/// onto the calling thread — including the main thread for SwiftUI views — and risk
/// UI hitches when the keychain daemon is slow.
///
/// The async signature lines up with `SecureStorageProtocol` so the whole token
/// read/write path remains a single `await` chain instead of bouncing between
/// detached tasks and the calling actor.
public protocol AuthTokenStoreProtocol: Sendable {
    func deviceID() async throws -> String
    func accessToken() async throws -> String?
    func save(tokens: TokenResponse, deviceID: String) async throws
    func clear() async throws

    /// Extracts user ID from stored token (optional, for convenience).
    func userID() async throws -> String?

    /// Checks if current user is a guest (optional, for convenience).
    func isGuest() async throws -> Bool

    // MARK: - Token Refresh Support

    /// Load access token with expiration time
    func loadAccessToken() async throws -> AuthToken?

    /// Save access token with expiration time
    func saveAccessToken(_ token: AuthToken) async throws
}

public struct SecureAuthTokenStore: AuthTokenStoreProtocol {
    private let storage: SecureStorageProtocol
    private let idGenerator: IDGeneratorProtocol

    public init(storage: SecureStorageProtocol, idGenerator: IDGeneratorProtocol) {
        self.storage = storage
        self.idGenerator = idGenerator
    }

    public func deviceID() async throws -> String {
        if let data = try await storage.read(key: AuthTokenStoreKey.deviceID),
           let existing = String(data: data, encoding: .utf8),
           !existing.isEmpty
        {
            return existing
        }
        let created = idGenerator.uuid().uuidString
        try await storage.write(Data(created.utf8), key: AuthTokenStoreKey.deviceID)
        return created
    }

    public func accessToken() async throws -> String? {
        guard let data = try await storage.read(key: AuthTokenStoreKey.accessToken) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func save(tokens: TokenResponse, deviceID: String) async throws {
        try await storage.write(Data(tokens.accessToken.utf8), key: AuthTokenStoreKey.accessToken)
        try await storage.write(Data(tokens.refreshToken.utf8), key: AuthTokenStoreKey.refreshToken)
        try await storage.write(Data(tokens.userID.utf8), key: AuthTokenStoreKey.userID)
        try await storage.write(Data(deviceID.utf8), key: AuthTokenStoreKey.deviceID)
        try await storage.write(Data((tokens.isGuest ? "1" : "0").utf8), key: AuthTokenStoreKey.isGuest)

        // Save token expiration time
        let expiresAt = Date().addingTimeInterval(TimeInterval(tokens.expiresIn))
        let expiresAtTimestamp = String(expiresAt.timeIntervalSince1970)
        try await storage.write(Data(expiresAtTimestamp.utf8), key: AuthTokenStoreKey.accessTokenExpiresAt)
    }

    public func clear() async throws {
        try await storage.delete(key: AuthTokenStoreKey.accessToken)
        try await storage.delete(key: AuthTokenStoreKey.accessTokenExpiresAt)
        try await storage.delete(key: AuthTokenStoreKey.refreshToken)
        try await storage.delete(key: AuthTokenStoreKey.userID)
        try await storage.delete(key: AuthTokenStoreKey.isGuest)
    }

    public func userID() async throws -> String? {
        guard let data = try await storage.read(key: AuthTokenStoreKey.userID) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func isGuest() async throws -> Bool {
        guard let data = try await storage.read(key: AuthTokenStoreKey.isGuest),
              let value = String(data: data, encoding: .utf8)
        else {
            // Default to true (guest) when unknown, matching pre-registration behavior.
            return true
        }
        return value == "1"
    }

    // MARK: - Token Refresh Support

    public func loadAccessToken() async throws -> AuthToken? {
        guard let tokenString = try await accessToken() else {
            return nil
        }

        // Load expiration time from storage
        guard let expiresAtData = try await storage.read(key: AuthTokenStoreKey.accessTokenExpiresAt),
              let expiresAtString = String(data: expiresAtData, encoding: .utf8),
              let expiresAtTimestamp = TimeInterval(expiresAtString) else {
            // If no expiration stored, return nil to force refresh
            return nil
        }

        let expiresAt = Date(timeIntervalSince1970: expiresAtTimestamp)
        return AuthToken(value: tokenString, expiresAt: expiresAt)
    }

    public func saveAccessToken(_ token: AuthToken) async throws {
        try await storage.write(Data(token.value.utf8), key: AuthTokenStoreKey.accessToken)

        // Save expiration time as timestamp
        let expiresAtTimestamp = String(token.expiresAt.timeIntervalSince1970)
        try await storage.write(Data(expiresAtTimestamp.utf8), key: AuthTokenStoreKey.accessTokenExpiresAt)
    }
}
