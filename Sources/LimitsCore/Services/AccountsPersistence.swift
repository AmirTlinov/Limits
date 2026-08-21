import Darwin
import Foundation
import LimitsShared

public enum AccountsPersistenceError: LocalizedError, Equatable {
    case lockFailed(Int32)
    case atomicReplaceFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .lockFailed(let code):
            return L10n.tr("accounts.persistence.lock_failed", code)
        case .atomicReplaceFailed(let code):
            return L10n.tr("accounts.persistence.atomic_replace_failed", code)
        }
    }
}

public struct AccountsPersistence: @unchecked Sendable {
    public let fileManager: FileManager
    public let baseURL: URL?

    public init(fileManager: FileManager = .default, baseURL: URL? = nil) {
        self.fileManager = fileManager
        self.baseURL = baseURL
    }

    public var stateDirectoryURL: URL {
        if let baseURL {
            return baseURL
        }

        let appSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return (appSupport ?? fileManager.homeDirectoryForCurrentUser)
            .appending(path: "Limits", directoryHint: .isDirectory)
    }

    public var stateURL: URL {
        stateDirectoryURL
            .appending(path: "state.json")
    }

    public var preV4BackupURL: URL {
        stateDirectoryURL.appending(path: "state.pre-v4.json")
    }

    public var lockURL: URL {
        stateDirectoryURL.appending(path: "state.lock")
    }

    public func load() throws -> PersistedStateV5 {
        guard let data = try loadData() else {
            return PersistedStateV5(accounts: [])
        }
        return try JSONDecoder.limits.decode(PersistedStateV5.self, from: data)
    }

    public func loadData() throws -> Data? {
        guard fileManager.fileExists(atPath: stateURL.path) else {
            return nil
        }
        return try Data(contentsOf: stateURL)
    }

    public func backupBeforeV4Migration(_ data: Data) throws {
        try secureDirectory()
        guard !fileManager.fileExists(atPath: preV4BackupURL.path) else {
            return
        }
        try writeAtomically(data, to: preV4BackupURL)
    }

    public func save(_ state: PersistedStateV5) throws {
        try secureDirectory()
        let data = try JSONEncoder.limits.encode(state)
        try writeAtomically(data, to: stateURL)
    }

    public func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        try secureDirectory()
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw AccountsPersistenceError.lockFailed(errno)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else {
            throw AccountsPersistenceError.lockFailed(errno)
        }
        defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lockURL.path)
        return try body()
    }

    private func secureDirectory() throws {
        try fileManager.createDirectory(
            at: stateDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDirectoryURL.path)
    }

    private func secureFile(_ url: URL) throws {
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func writeAtomically(_ data: Data, to destination: URL) throws {
        let temporary = stateDirectoryURL.appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
            try secureFile(temporary)
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.synchronize()
            try handle.close()

            guard Darwin.rename(temporary.path, destination.path) == 0 else {
                throw AccountsPersistenceError.atomicReplaceFailed(errno)
            }
            try secureFile(destination)

            let directoryDescriptor = Darwin.open(stateDirectoryURL.path, O_RDONLY)
            if directoryDescriptor >= 0 {
                _ = Darwin.fsync(directoryDescriptor)
                Darwin.close(directoryDescriptor)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }
}

extension JSONEncoder {
    public static var limits: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    public static var limits: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
