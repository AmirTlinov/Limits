import Foundation
import Security

enum GlobalClaudeCredentialServiceError: LocalizedError {
    case missingCredential
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            return "Текущая авторизация Claude Code не найдена в Keychain."
        case .unexpectedStatus(let status):
            return "Keychain Claude Code вернул ошибку \(status)."
        }
    }
}

struct GlobalClaudeCredentialService {
    let service = "Claude Code-credentials"

    func hasGlobalCredential() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    func readGlobalCredential() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw GlobalClaudeCredentialServiceError.missingCredential
            }
            return data
        case errSecItemNotFound:
            throw GlobalClaudeCredentialServiceError.missingCredential
        default:
            throw GlobalClaudeCredentialServiceError.unexpectedStatus(status)
        }
    }

    func writeGlobalCredential(_ data: Data) throws {
        let account = try currentAccountName()
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]

        let status = SecItemCopyMatching(baseQuery as CFDictionary, nil)

        switch status {
        case errSecSuccess:
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw GlobalClaudeCredentialServiceError.unexpectedStatus(updateStatus)
            }
        case errSecItemNotFound:
            var addQuery = baseQuery
            attributes.forEach { addQuery[$0.key] = $0.value }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw GlobalClaudeCredentialServiceError.unexpectedStatus(addStatus)
            }
        default:
            throw GlobalClaudeCredentialServiceError.unexpectedStatus(status)
        }
    }

    private func currentAccountName() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            if
                let attributes = item as? [String: Any],
                let account = attributes[kSecAttrAccount as String] as? String,
                !account.isEmpty
            {
                return account
            }
            return NSUserName()
        case errSecItemNotFound:
            return NSUserName()
        default:
            throw GlobalClaudeCredentialServiceError.unexpectedStatus(status)
        }
    }
}
