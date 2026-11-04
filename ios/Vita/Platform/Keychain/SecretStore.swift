import Foundation
import Security

/// 敏感值的键。设备令牌只存 Keychain，不进 UserDefaults / 日志（架构设计 §8）；
/// 模型密钥只在服务端，手机上没有（ADR-013）。
enum SecretKey: String, Sendable {
    /// Vita API 的设备令牌，在 Admin 的“设备”页签发。
    case deviceToken = "vita-api.device-token"
    /// 1.0 的 Conduit 令牌；2.0 不再使用，迁移完成后删掉。
    case conduitToken = "conduit.token"
}

enum SecretStoreError: Error, Equatable {
    /// 仅携带 Keychain 状态码；绝不包含密钥内容。
    case keychain(status: Int32)
    case invalidData
}

protocol SecretStore: Sendable {
    func read(_ key: SecretKey) throws -> String?
    func write(_ value: String, for key: SecretKey) throws
    func delete(_ key: SecretKey) throws
}

struct KeychainSecretStore: SecretStore {
    let service: String

    init(service: String = "com.leonardo.vita") {
        self.service = service
    }

    private func baseQuery(_ key: SecretKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }

    func read(_ key: SecretKey) throws -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
                throw SecretStoreError.invalidData
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw SecretStoreError.keychain(status: status)
        }
    }

    func write(_ value: String, for key: SecretKey) throws {
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(key) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(key)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw SecretStoreError.keychain(status: addStatus) }
        } else if status != errSecSuccess {
            throw SecretStoreError.keychain(status: status)
        }
    }

    func delete(_ key: SecretKey) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.keychain(status: status)
        }
    }
}

/// 测试替身。
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SecretKey: String] = [:]

    func read(_ key: SecretKey) throws -> String? {
        lock.withLock { storage[key] }
    }

    func write(_ value: String, for key: SecretKey) throws {
        lock.withLock { storage[key] = value }
    }

    func delete(_ key: SecretKey) throws {
        lock.withLock { _ = storage.removeValue(forKey: key) }
    }
}
