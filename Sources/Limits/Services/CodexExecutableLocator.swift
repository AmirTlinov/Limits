import Foundation

enum CodexExecutableLocatorError: LocalizedError {
    case notFound

    var errorDescription: String? {
        "Could not locate the `codex` executable. Install Codex CLI or ensure `command -v codex` works in zsh."
    }
}

enum CodexExecutableLocator {
    static func locate() throws -> URL {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v codex"]
        process.standardOutput = stdout
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if
            process.terminationStatus == 0,
            let output,
            !output.isEmpty
        {
            return URL(fileURLWithPath: output)
        }

        let fallbacks = [
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
        ]

        if let fallback = fallbacks.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return fallback
        }

        throw CodexExecutableLocatorError.notFound
    }
}
