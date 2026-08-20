import Foundation
import LimitsShared

public enum GlobalCodexAuthServiceError: LocalizedError, Equatable {
    case missingAuthFile
    case concurrentModification
    case committedDataMismatch

    public var errorDescription: String? {
        switch self {
        case .missingAuthFile:
            return L10n.tr("codex.auth.global_missing")
        case .concurrentModification:
            return L10n.tr("account.switch.concurrent_change")
        case .committedDataMismatch:
            return L10n.tr("account.switch.verification_failed")
        }
    }
}

public struct GlobalCodexAuthSnapshot: Equatable, Sendable {
    public let data: Data?

    public var fingerprint: String? {
        data.map { CodexAuthBlob.fingerprint(for: $0) }
    }

    public init(data: Data?) {
        self.data = data
    }
}

public protocol GlobalCodexAuthStoring: Sendable {
    func readSnapshot() throws -> GlobalCodexAuthSnapshot
    func commit(expected: GlobalCodexAuthSnapshot, replacement: Data) throws
    func verifyCommitted(_ replacement: Data) throws
    func restore(_ original: GlobalCodexAuthSnapshot, replacing replacement: Data) throws
}

public struct GlobalCodexAuthService: GlobalCodexAuthStoring, @unchecked Sendable {
    public let fileManager: FileManager
    private let overriddenAuthURL: URL?
    private let processLock: InterprocessFileLock

    public init(fileManager: FileManager = .default, authURL: URL? = nil) {
        self.fileManager = fileManager
        overriddenAuthURL = authURL
        let resolvedAuthURL = authURL ?? fileManager.homeDirectoryForCurrentUser
            .appending(path: ".codex", directoryHint: .isDirectory)
            .appending(path: "auth.json")
        processLock = InterprocessFileLock(
            url: resolvedAuthURL.deletingLastPathComponent().appending(path: ".limits-auth.lock"),
            fileManager: fileManager
        )
    }

    public var authURL: URL {
        overriddenAuthURL ?? fileManager.homeDirectoryForCurrentUser
            .appending(path: ".codex", directoryHint: .isDirectory)
            .appending(path: "auth.json")
    }

    public func hasGlobalAuth() -> Bool {
        (try? readSnapshot().data) != nil
    }

    public func readGlobalAuth() throws -> Data {
        guard let data = try readSnapshot().data else {
            throw GlobalCodexAuthServiceError.missingAuthFile
        }
        return data
    }

    public func readSnapshot() throws -> GlobalCodexAuthSnapshot {
        try processLock.withLock { try readSnapshotUnlocked() }
    }

    private func readSnapshotUnlocked() throws -> GlobalCodexAuthSnapshot {
        guard fileManager.fileExists(atPath: authURL.path) else {
            return GlobalCodexAuthSnapshot(data: nil)
        }
        return GlobalCodexAuthSnapshot(data: try Data(contentsOf: authURL))
    }

    public func commit(expected: GlobalCodexAuthSnapshot, replacement: Data) throws {
        try processLock.withLock {
            guard try readSnapshotUnlocked().fingerprint == expected.fingerprint else {
                throw GlobalCodexAuthServiceError.concurrentModification
            }
            try write(replacement)
            guard try readSnapshotUnlocked().fingerprint == CodexAuthBlob.fingerprint(for: replacement) else {
                throw GlobalCodexAuthServiceError.committedDataMismatch
            }
        }
    }

    public func verifyCommitted(_ replacement: Data) throws {
        try processLock.withLock {
            guard try readSnapshotUnlocked().fingerprint == CodexAuthBlob.fingerprint(for: replacement) else {
                throw GlobalCodexAuthServiceError.committedDataMismatch
            }
        }
    }

    public func restore(_ original: GlobalCodexAuthSnapshot, replacing replacement: Data) throws {
        try processLock.withLock {
            let current = try readSnapshotUnlocked()
            if current.fingerprint == original.fingerprint { return }
            guard current.fingerprint == CodexAuthBlob.fingerprint(for: replacement) else {
                throw GlobalCodexAuthServiceError.concurrentModification
            }
            if let originalData = original.data {
                try write(originalData)
            } else if fileManager.fileExists(atPath: authURL.path) {
                try fileManager.removeItem(at: authURL)
            }
        }
    }

    private func write(_ data: Data) throws {
        let parent = authURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            try fileManager.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try data.write(to: authURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
    }
}
