import Foundation
import LimitsShared

public enum ClaudeExecutableLocatorError: LocalizedError {
    case notFound

    public var errorDescription: String? {
        L10n.tr("claude.cli.not_found")
    }
}

public enum ClaudeAuthStatusServiceError: LocalizedError {
    case unreadableOutput
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableOutput:
            return L10n.tr("claude.status.unreadable")
        case .commandFailed(let detail):
            return L10n.tr("claude.status.command_failed", detail)
        }
    }
}

public struct ClaudeAuthStatus: Decodable, Hashable, Sendable {
    public let loggedIn: Bool
    public let authMethod: String?
    public let apiProvider: String?
    public let email: String?
    public let orgId: String?
    public let orgName: String?
    public let subscriptionType: String?

    public init(loggedIn: Bool, authMethod: String?, apiProvider: String?, email: String?, orgId: String?, orgName: String?, subscriptionType: String?) {
        self.loggedIn = loggedIn
        self.authMethod = authMethod
        self.apiProvider = apiProvider
        self.email = email
        self.orgId = orgId
        self.orgName = orgName
        self.subscriptionType = subscriptionType
    }

    public var stableIdentity: ClaudeAccountIdentity? {
        ClaudeAccountIdentity(email: email, organizationId: orgId)
    }
}

public enum ClaudeExecutableLocator {
    public static func locate(
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

public struct ClaudeAuthStatusService: Sendable {
    private let executableURL: URL?
    private let runner: AsyncCommandRunner
    private let timeout: TimeInterval

    public init(
        executableURL: URL? = nil,
        runner: AsyncCommandRunner = AsyncCommandRunner(),
        timeout: TimeInterval = 10
    ) {
        self.executableURL = executableURL
        self.runner = runner
        self.timeout = timeout
    }

    public func isInstalled() -> Bool {
        executableURL != nil || (try? ClaudeExecutableLocator.locate()) != nil
    }

    public func readStatus() async throws -> ClaudeAuthStatus {
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
                : L10n.tr("claude.status.exit_code", result.terminationStatus)
            throw ClaudeAuthStatusServiceError.commandFailed(detail)
        }

        return try JSONDecoder.limits.decode(ClaudeAuthStatus.self, from: result.standardOutput)
    }
}
