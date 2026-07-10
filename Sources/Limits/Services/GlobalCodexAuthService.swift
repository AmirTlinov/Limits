import Foundation

enum GlobalCodexAuthServiceError: LocalizedError, Equatable {
    case missingAuthFile
    case concurrentModification
    case committedDataMismatch

    var errorDescription: String? {
        switch self {
        case .missingAuthFile:
            return "Global ~/.codex/auth.json does not exist."
        case .concurrentModification:
            return L10n.tr("account.switch.concurrent_change")
        case .committedDataMismatch:
            return L10n.tr("account.switch.verification_failed")
        }
    }
}

struct GlobalCodexAuthSnapshot: Equatable, Sendable {
    let data: Data?
}

protocol GlobalCodexAuthStoring: Sendable {
    func readSnapshot() throws -> GlobalCodexAuthSnapshot
    func commit(expected: GlobalCodexAuthSnapshot, replacement: Data) throws
    func verifyCommitted(_ replacement: Data) throws
    func restore(_ original: GlobalCodexAuthSnapshot, replacing replacement: Data) throws
}

struct GlobalCodexAuthService: GlobalCodexAuthStoring, @unchecked Sendable {
    let fileManager: FileManager
    private let overriddenAuthURL: URL?

    init(fileManager: FileManager = .default, authURL: URL? = nil) {
        self.fileManager = fileManager
        overriddenAuthURL = authURL
    }

    var authURL: URL {
        overriddenAuthURL ?? fileManager.homeDirectoryForCurrentUser
            .appending(path: ".codex", directoryHint: .isDirectory)
            .appending(path: "auth.json")
    }

    func hasGlobalAuth() -> Bool {
        fileManager.fileExists(atPath: authURL.path)
    }

    func readGlobalAuth() throws -> Data {
        guard let data = try readSnapshot().data else {
            throw GlobalCodexAuthServiceError.missingAuthFile
        }
        return data
    }

    func readSnapshot() throws -> GlobalCodexAuthSnapshot {
        guard hasGlobalAuth() else {
            return GlobalCodexAuthSnapshot(data: nil)
        }
        return GlobalCodexAuthSnapshot(data: try Data(contentsOf: authURL))
    }

    func commit(expected: GlobalCodexAuthSnapshot, replacement: Data) throws {
        guard try readSnapshot() == expected else {
            throw GlobalCodexAuthServiceError.concurrentModification
        }
        try write(replacement)
    }

    func verifyCommitted(_ replacement: Data) throws {
        guard try readSnapshot().data == replacement else {
            throw GlobalCodexAuthServiceError.committedDataMismatch
        }
    }

    func restore(_ original: GlobalCodexAuthSnapshot, replacing replacement: Data) throws {
        let current = try readSnapshot()
        if current == original {
            return
        }
        guard current.data == replacement else {
            throw GlobalCodexAuthServiceError.concurrentModification
        }

        if let originalData = original.data {
            try write(originalData)
        } else if hasGlobalAuth() {
            try fileManager.removeItem(at: authURL)
        }
    }

    func materializeAuth(_ data: Data, in codexHome: URL) throws {
        try fileManager.createDirectory(
            at: codexHome,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let authURL = codexHome.appending(path: "auth.json")
        try data.write(to: authURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
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
