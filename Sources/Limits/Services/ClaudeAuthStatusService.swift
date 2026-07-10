import Foundation

enum ClaudeExecutableLocatorError: LocalizedError {
    case notFound

    var errorDescription: String? {
        L10n.tr("claude.cli.not_found")
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

struct ClaudeAuthStatus: Decodable, Hashable, Sendable {
    let loggedIn: Bool
    let authMethod: String?
    let apiProvider: String?
    let email: String?
    let orgId: String?
    let orgName: String?
    let subscriptionType: String?

    var stableIdentity: ClaudeAccountIdentity? {
        ClaudeAccountIdentity(email: email, organizationId: orgId)
    }
}

enum ClaudeExecutableLocator {
    static func locate(
        environmentPath: String? = ProcessInfo.processInfo.environment["PATH"],
        fileManager: FileManager = .default
    ) throws -> URL {
        let home = fileManager.homeDirectoryForCurrentUser
        let pathCandidates = (environmentPath ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appending(path: "claude") }
        let fallbacks = [
            home.appending(path: ".local/bin/claude"),
            home.appending(path: ".volta/bin/claude"),
            home.appending(path: ".local/share/fnm/aliases/default/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]

        var seen = Set<String>()
        if let executable = (pathCandidates + fallbacks).first(where: {
            seen.insert($0.path).inserted && fileManager.isExecutableFile(atPath: $0.path)
        }) {
            return executable
        }
        throw ClaudeExecutableLocatorError.notFound
    }
}

struct ClaudeAuthStatusService: Sendable {
    private let executableURL: URL?
    private let runner: AsyncCommandRunner
    private let timeout: TimeInterval

    init(
        executableURL: URL? = nil,
        runner: AsyncCommandRunner = AsyncCommandRunner(),
        timeout: TimeInterval = 10
    ) {
        self.executableURL = executableURL
        self.runner = runner
        self.timeout = timeout
    }

    func isInstalled() -> Bool {
        executableURL != nil || (try? ClaudeExecutableLocator.locate()) != nil
    }

    func readStatus() async throws -> ClaudeAuthStatus {
        let executableURL = try executableURL ?? ClaudeExecutableLocator.locate()
        let result = try await runner.run(
            executableURL: executableURL,
            arguments: ["auth", "status", "--json"],
            timeout: timeout
        )

        guard !result.standardOutput.isEmpty else {
            throw ClaudeAuthStatusServiceError.unreadableOutput
        }
        guard result.terminationStatus == 0 else {
            let errorOutput = String(data: result.standardError, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = errorOutput?.isEmpty == false
                ? errorOutput!
                : "Claude Code завершился с кодом \(result.terminationStatus)."
            throw ClaudeAuthStatusServiceError.commandFailed(detail)
        }

        return try JSONDecoder.limits.decode(ClaudeAuthStatus.self, from: result.standardOutput)
    }
}
