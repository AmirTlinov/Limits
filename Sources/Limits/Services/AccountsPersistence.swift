import Foundation

struct AccountsPersistence {
    let fileManager: FileManager = .default

    var stateURL: URL {
        let appSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return (appSupport ?? fileManager.homeDirectoryForCurrentUser)
            .appending(path: "Limits", directoryHint: .isDirectory)
            .appending(path: "state.json")
    }

    func load() throws -> PersistedState {
        guard fileManager.fileExists(atPath: stateURL.path) else {
            return PersistedState(accounts: [])
        }
        let data = try Data(contentsOf: stateURL)
        return try JSONDecoder.limits.decode(PersistedState.self, from: data)
    }

    func save(_ state: PersistedState) throws {
        let dir = stateURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        let data = try JSONEncoder.limits.encode(state)
        try data.write(to: stateURL, options: .atomic)
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
