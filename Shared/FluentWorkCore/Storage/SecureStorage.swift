import Foundation
import Security

/// Wraps synchronous `SecItem*` calls in a detached `Task` so they never block the
/// calling thread (especially the main thread in SwiftUI apps). The keychain daemon
/// itself handles concurrent-access serialization internally.
public protocol SecureStorageProtocol: Sendable {
    func read(key: String) async throws -> Data?
    func write(_ data: Data, key: String) async throws
    func delete(key: String) async throws
}

public enum SecureStorageError: Error, Equatable, Sendable {
    case unexpectedStatus(OSStatus)
    case encodingFailed
}

public struct KeychainSecureStorage: SecureStorageProtocol {
    private let service: String

    public init(service: String = "com.fluentwork.secure") {
        self.service = service
    }

    public func read(key: String) async throws -> Data? {
        try await Task.detached(priority: .userInitiated) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: self.service,
                kSecAttrAccount as String: key,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]

            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            switch status {
            case errSecSuccess:
                return item as? Data
            case errSecItemNotFound:
                return nil
            default:
                throw SecureStorageError.unexpectedStatus(status)
            }
        }.value
    }

    public func write(_ data: Data, key: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: self.service,
                kSecAttrAccount as String: key,
            ]
            _ = SecItemDelete(deleteQuery as CFDictionary)

            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: self.service,
                kSecAttrAccount as String: key,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]

            let status = SecItemAdd(addQuery as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw SecureStorageError.unexpectedStatus(status)
            }
        }.value
    }

    public func delete(key: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: self.service,
                kSecAttrAccount as String: key,
            ]

            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw SecureStorageError.unexpectedStatus(status)
            }
        }.value
    }
}

/// Actor-isolated instead of `DispatchQueue.sync`: once `SecureStorageProtocol`
/// is async, the test fake should mirror real concurrency behavior so callers
/// can exercise the same code paths without surprising the actor reentrancy model.
public actor InMemorySecureStorage: SecureStorageProtocol {
    private var storage: [String: Data] = [:]

    public init() {}

    public func read(key: String) async throws -> Data? {
        storage[key]
    }

    public func write(_ data: Data, key: String) async throws {
        storage[key] = data
    }

    public func delete(key: String) async throws {
        storage.removeValue(forKey: key)
    }
}
