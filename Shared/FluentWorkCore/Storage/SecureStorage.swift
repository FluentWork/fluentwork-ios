import Foundation
import Security

public protocol SecureStorageProtocol: Sendable {
    func read(key: String) throws -> Data?
    func write(_ data: Data, key: String) throws
    func delete(key: String) throws
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

    public func read(key: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
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
    }

    public func write(_ data: Data, key: String) throws {
        try delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecureStorageError.unexpectedStatus(status)
        }
    }

    public func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureStorageError.unexpectedStatus(status)
        }
    }
}

public final class InMemorySecureStorage: SecureStorageProtocol, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.fluentwork.secure-storage")
    private var storage: [String: Data] = [:]

    public init() {}

    public func read(key: String) throws -> Data? {
        queue.sync {
            storage[key]
        }
    }

    public func write(_ data: Data, key: String) throws {
        queue.sync {
            storage[key] = data
        }
    }

    public func delete(key: String) throws {
        _ = queue.sync {
            storage.removeValue(forKey: key)
        }
    }
}
