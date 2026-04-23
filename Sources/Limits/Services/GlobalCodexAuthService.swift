import Foundation

enum GlobalCodexAuthServiceError: LocalizedError {
    case missingAuthFile

    var errorDescription: String? {
        switch self {
        case .missingAuthFile:
            return "Global ~/.codex/auth.json does not exist."
        }
    }
}

struct GlobalCodexAuthService: @unchecked Sendable {
    let fileManager: FileManager = .default

    var authURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appending(path: ".codex", directoryHint: .isDirectory)
            .appending(path: "auth.json")
    }

    func hasGlobalAuth() -> Bool {
        fileManager.fileExists(atPath: authURL.path)
    }

    func readGlobalAuth() throws -> Data {
        guard hasGlobalAuth() else {
            throw GlobalCodexAuthServiceError.missingAuthFile
        }
        return try Data(contentsOf: authURL)
    }

    func writeGlobalAuth(_ data: Data) throws {
        let parent = authURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: nil)

        let tempURL = parent.appending(path: ".auth.json.tmp.\(UUID().uuidString)")
        try data.write(to: tempURL, options: [])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)

        if fileManager.fileExists(atPath: authURL.path) {
            _ = try fileManager.replaceItemAt(authURL, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: authURL)
        }

        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
    }

    func materializeAuth(_ data: Data, in codexHome: URL) throws {
        try fileManager.createDirectory(at: codexHome, withIntermediateDirectories: true, attributes: nil)
        let authURL = codexHome.appending(path: "auth.json")
        try data.write(to: authURL, options: [])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
    }
}
