import Foundation

struct AccountsPersistence {
    let fileManager: FileManager
    let baseURL: URL?

    init(fileManager: FileManager = .default, baseURL: URL? = nil) {
        self.fileManager = fileManager
        self.baseURL = baseURL
    }

    var stateDirectoryURL: URL {
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

    var stateURL: URL {
        stateDirectoryURL
            .appending(path: "state.json")
    }

    var preV2BackupURL: URL {
        stateDirectoryURL.appending(path: "state.pre-v2.json")
    }

    func load() throws -> PersistedState {
        guard let data = try loadData() else {
            return PersistedState(accounts: [])
        }
        return try JSONDecoder.limits.decode(PersistedState.self, from: data)
    }

    func loadData() throws -> Data? {
        guard fileManager.fileExists(atPath: stateURL.path) else {
            return nil
        }
        return try Data(contentsOf: stateURL)
    }

    func backupBeforeV2Migration(_ data: Data) throws {
        try secureDirectory()
        guard !fileManager.fileExists(atPath: preV2BackupURL.path) else {
            return
        }
        try data.write(to: preV2BackupURL, options: .atomic)
        try secureFile(preV2BackupURL)
    }

    func save(_ state: PersistedState) throws {
        try secureDirectory()
        let data = try JSONEncoder.limits.encode(state)
        try data.write(to: stateURL, options: .atomic)
        try secureFile(stateURL)
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
}

extension JSONEncoder {
    static var limits: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var limits: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
