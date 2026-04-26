import Foundation
import Security

enum KeychainAuthVaultError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case missingEntry

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain operation failed with status \(status)."
        case .missingEntry:
            return "Auth blob is missing from the keychain."
        }
    }
}

protocol KeychainAuthDataStore {
    func save(_ data: Data, account: String, label: String) throws
    func read(account: String) throws -> Data
    func delete(account: String) throws
}

final class KeychainAuthVault {
    private let store: KeychainAuthDataStore
    /// Process-local only. The durable secret stays in Keychain.
    /// This prevents repeated macOS consent dialogs for the same saved account
    /// after the user has already approved one access in the current app run.
    private var cachedDataByAccount: [String: Data] = [:]

    init(store: KeychainAuthDataStore = SystemKeychainAuthDataStore()) {
        self.store = store
    }

    func save(_ data: Data, account: String, label: String) throws {
        try store.save(data, account: account, label: label)
        cachedDataByAccount[account] = data
    }

    func read(account: String) throws -> Data {
        if let cachedData = cachedDataByAccount[account] {
            return cachedData
        }

        let data = try store.read(account: account)
        cachedDataByAccount[account] = data
        return data
    }

    func delete(account: String) throws {
        try store.delete(account: account)
        cachedDataByAccount.removeValue(forKey: account)
    }
}

private struct SystemKeychainAuthDataStore: KeychainAuthDataStore {
    let service = "com.amir.Limits.authblob"

    func save(_ data: Data, account: String, label: String) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: label,
        ]

        let status = SecItemCopyMatching(baseQuery as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainAuthVaultError.unexpectedStatus(updateStatus)
            }
        case errSecItemNotFound:
            var addQuery = baseQuery
            attributes.forEach { addQuery[$0.key] = $0.value }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainAuthVaultError.unexpectedStatus(addStatus)
            }
        default:
            throw KeychainAuthVaultError.unexpectedStatus(status)
        }
    }

    func read(account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw KeychainAuthVaultError.missingEntry
            }
            return data
        case errSecItemNotFound:
            throw KeychainAuthVaultError.missingEntry
        default:
            throw KeychainAuthVaultError.unexpectedStatus(status)
        }
    }

    func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainAuthVaultError.unexpectedStatus(status)
        }
    }
}
