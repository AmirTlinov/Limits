import Foundation

enum ClaudeExecutableLocatorError: LocalizedError {
    case notFound

    var errorDescription: String? {
        "Не удалось найти `claude`. Установите Claude Code или убедитесь, что `command -v claude` работает в zsh."
    }
}

enum ClaudeAuthStatusServiceError: LocalizedError {
    case unreadableOutput
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadableOutput:
            return "Claude Code вернул нечитаемый ответ."
        case .commandFailed(let detail):
            return detail
        }
    }
}

struct ClaudeAuthStatus: Decodable, Hashable {
    let loggedIn: Bool
    let authMethod: String?
    let apiProvider: String?
    let email: String?
    let orgId: String?
    let orgName: String?
    let subscriptionType: String?
}

enum ClaudeExecutableLocator {
    static func locate() throws -> URL {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v claude"]
        process.standardOutput = stdout
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if process.terminationStatus == 0, let output, !output.isEmpty {
            return URL(fileURLWithPath: output)
        }

        let fallbacks = [
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]

        if let fallback = fallbacks.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return fallback
        }

        throw ClaudeExecutableLocatorError.notFound
    }
}

struct ClaudeAuthStatusService {
    func isInstalled() -> Bool {
        (try? ClaudeExecutableLocator.locate()) != nil
    }

    func readStatus() throws -> ClaudeAuthStatus {
        let executableURL = try ClaudeExecutableLocator.locate()

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executableURL
        process.arguments = ["auth", "status", "--json"]
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !output.isEmpty else {
            throw ClaudeAuthStatusServiceError.unreadableOutput
        }

        if process.terminationStatus != 0 {
            let detail = errorOutput?.isEmpty == false ? errorOutput! : "Claude Code завершился с кодом \(process.terminationStatus)."
            throw ClaudeAuthStatusServiceError.commandFailed(detail)
        }

        return try JSONDecoder.limits.decode(ClaudeAuthStatus.self, from: output)
    }
}
