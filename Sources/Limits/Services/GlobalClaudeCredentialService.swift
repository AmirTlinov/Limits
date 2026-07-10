import Foundation
import Security

enum GlobalClaudeCredentialServiceError: LocalizedError, Equatable {
    case missingCredential
    case unexpectedStatus(OSStatus)
    case concurrentModification
    case committedDataMismatch

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            return L10n.tr("claude.auth.keychain_missing")
        case .unexpectedStatus(let status):
            return L10n.tr("claude.auth.keychain_error", status)
        case .concurrentModification:
            return L10n.tr("claude.switch.concurrent_change")
        case .committedDataMismatch:
            return L10n.tr("claude.switch.verification_failed")
        }
    }
}

struct GlobalClaudeCredentialSnapshot: Equatable, Sendable {
    let account: String?
    let data: Data?
}

protocol GlobalClaudeCredentialStoring: Sendable {
    func readSnapshot() throws -> GlobalClaudeCredentialSnapshot
    func commit(expected: GlobalClaudeCredentialSnapshot, replacement: Data) throws
    func verifyCommitted(_ replacement: Data, basedOn original: GlobalClaudeCredentialSnapshot) throws
    func restore(_ original: GlobalClaudeCredentialSnapshot, replacing replacement: Data) throws
}

struct GlobalClaudeCredentialService: GlobalClaudeCredentialStoring, Sendable {
    let service = "Claude Code-credentials"

    func hasGlobalCredential() -> Bool {
        (try? readSnapshot().data) != nil
    }

    func readGlobalCredential() throws -> Data {
        guard let data = try readSnapshot().data else {
            throw GlobalClaudeCredentialServiceError.missingCredential
        }
        return data
    }

    func readSnapshot() throws -> GlobalClaudeCredentialSnapshot {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard
                let attributes = item as? [String: Any],
                let data = attributes[kSecValueData as String] as? Data
            else {
                throw GlobalClaudeCredentialServiceError.missingCredential
            }
            return GlobalClaudeCredentialSnapshot(
                account: attributes[kSecAttrAccount as String] as? String,
                data: data
            )
        case errSecItemNotFound:
            return GlobalClaudeCredentialSnapshot(account: nil, data: nil)
        default:
            throw GlobalClaudeCredentialServiceError.unexpectedStatus(status)
        }
    }

    func commit(expected: GlobalClaudeCredentialSnapshot, replacement: Data) throws {
        guard try readSnapshot() == expected else {
            throw GlobalClaudeCredentialServiceError.concurrentModification
        }
        try write(replacement, account: expected.account ?? NSUserName())
    }

    func verifyCommitted(_ replacement: Data, basedOn original: GlobalClaudeCredentialSnapshot) throws {
        let committed = try readSnapshot()
        guard
            committed.data == replacement,
            committed.account == (original.account ?? NSUserName())
        else {
            throw GlobalClaudeCredentialServiceError.committedDataMismatch
        }
    }

    func restore(_ original: GlobalClaudeCredentialSnapshot, replacing replacement: Data) throws {
        let current = try readSnapshot()
        if current == original {
            return
        }
        guard current.data == replacement else {
            throw GlobalClaudeCredentialServiceError.concurrentModification
        }

        if let originalData = original.data {
            try write(originalData, account: original.account ?? NSUserName())
        } else if let currentAccount = current.account {
            try delete(account: currentAccount)
        }
    }

    private func write(_ data: Data, account: String) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
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

    private func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GlobalClaudeCredentialServiceError.unexpectedStatus(status)
        }
    }
}
