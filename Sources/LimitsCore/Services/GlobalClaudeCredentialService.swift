import Foundation
import Security
import LimitsShared

public enum GlobalClaudeCredentialServiceError: LocalizedError, Equatable {
    case missingCredential
    case unexpectedStatus(OSStatus)
    case concurrentModification
    case committedDataMismatch

    public var errorDescription: String? {
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

public struct GlobalClaudeCredentialSnapshot: Equatable, Sendable {
    public let account: String?
    public let data: Data?

    public var fingerprint: String? {
        data.map { CodexAuthBlob.fingerprint(for: $0) }
    }

    public init(account: String?, data: Data?) {
        self.account = account
        self.data = data
    }
}

public protocol GlobalClaudeCredentialStoring: Sendable {
    func readSnapshot() throws -> GlobalClaudeCredentialSnapshot
    func commit(expected: GlobalClaudeCredentialSnapshot, replacement: Data) throws
    func verifyCommitted(_ replacement: Data, basedOn original: GlobalClaudeCredentialSnapshot) throws
    func restore(_ original: GlobalClaudeCredentialSnapshot, replacing replacement: Data) throws
}

public struct GlobalClaudeCredentialService: GlobalClaudeCredentialStoring, @unchecked Sendable {
    public let service = "Claude Code-credentials"
    private let processLock: InterprocessFileLock

    public init(fileManager: FileManager = .default, lockURL: URL? = nil) {
        let resolvedLockURL = lockURL ?? (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ))?.appending(path: "Limits/global-claude.lock")
            ?? fileManager.temporaryDirectory.appending(path: "Limits-global-claude.lock")
        processLock = InterprocessFileLock(url: resolvedLockURL, fileManager: fileManager)
    }

    public func hasGlobalCredential() -> Bool {
        (try? readSnapshot().data) != nil
    }

    public func readGlobalCredential() throws -> Data {
        guard let data = try readSnapshot().data else {
            throw GlobalClaudeCredentialServiceError.missingCredential
        }
        return data
    }

    public func readSnapshot() throws -> GlobalClaudeCredentialSnapshot {
        try processLock.withLock { try readSnapshotUnlocked() }
    }

    private func readSnapshotUnlocked() throws -> GlobalClaudeCredentialSnapshot {
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

    public func commit(expected: GlobalClaudeCredentialSnapshot, replacement: Data) throws {
        try processLock.withLock {
            let current = try readSnapshotUnlocked()
            guard current.account == expected.account, current.fingerprint == expected.fingerprint else {
                throw GlobalClaudeCredentialServiceError.concurrentModification
            }
            try write(replacement, account: expected.account ?? NSUserName())
            let committed = try readSnapshotUnlocked()
            guard committed.account == (expected.account ?? NSUserName()),
                  committed.fingerprint == CodexAuthBlob.fingerprint(for: replacement) else {
                throw GlobalClaudeCredentialServiceError.committedDataMismatch
            }
        }
    }

    public func verifyCommitted(_ replacement: Data, basedOn original: GlobalClaudeCredentialSnapshot) throws {
        try processLock.withLock {
            let committed = try readSnapshotUnlocked()
            guard
                committed.fingerprint == CodexAuthBlob.fingerprint(for: replacement),
                committed.account == (original.account ?? NSUserName())
            else {
                throw GlobalClaudeCredentialServiceError.committedDataMismatch
            }
        }
    }

    public func restore(_ original: GlobalClaudeCredentialSnapshot, replacing replacement: Data) throws {
        try processLock.withLock {
            let current = try readSnapshotUnlocked()
            if current.account == original.account, current.fingerprint == original.fingerprint { return }
            guard current.fingerprint == CodexAuthBlob.fingerprint(for: replacement) else {
                throw GlobalClaudeCredentialServiceError.concurrentModification
            }
            if let originalData = original.data {
                try write(originalData, account: original.account ?? NSUserName())
            } else if let currentAccount = current.account {
                try delete(account: currentAccount)
            }
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
