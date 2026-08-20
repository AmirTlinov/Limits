import Darwin
import Foundation
import LimitsShared

@frozen public enum CodexShellProbeOutcome: Equatable, Sendable {
    case success
    case timedOut
    case launchFailed(String)
    case exited(Int32)
}

public enum CodexExecutableLocatorError: LocalizedError {
    case notFound(CodexShellProbeOutcome)
    case nodeNotFound(codexURL: URL, searchedPath: String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let outcome):
            return L10n.tr("codex.executable.not_found", outcome.localizedDescription)
        case .nodeNotFound(let codexURL, let searchedPath):
            return L10n.tr("codex.executable.node_missing", codexURL.path, searchedPath)
        }
    }
}

private extension CodexShellProbeOutcome {
    var localizedDescription: String {
        switch self {
        case .success:
            return L10n.tr("codex.executable.probe.success")
        case .timedOut:
            return L10n.tr("codex.executable.probe.timeout")
        case .launchFailed(let detail):
            return L10n.tr("codex.executable.probe.launch_failed", detail)
        case .exited(let status):
            return L10n.tr("codex.executable.probe.exit_code", status)
        }
    }
}

public struct CodexExecutableResolution: Sendable, Equatable {
    public let executableURL: URL
    public let environment: [String: String]
    public let shellProbeOutcome: CodexShellProbeOutcome
}

public enum CodexExecutableLocator {
    private struct ShellResolution {
        let path: String
        let codexPath: String?
        let nodePath: String?
        let outcome: CodexShellProbeOutcome
    }

    public static func locate() throws -> CodexExecutableResolution {
        let shell = shellResolution(timeout: 2)
        let environment = resolvedEnvironment(shellPath: shell.path, baseEnvironment: ProcessInfo.processInfo.environment)
        guard let executableURL = executableURL(shellPath: shell.codexPath, environmentPath: environment["PATH"]) else {
            throw CodexExecutableLocatorError.notFound(shell.outcome)
        }
        if requiresNode(executableURL), nodeURL(shellPath: shell.nodePath, environmentPath: environment["PATH"]) == nil {
            throw CodexExecutableLocatorError.nodeNotFound(codexURL: executableURL, searchedPath: environment["PATH"] ?? "")
        }
        return CodexExecutableResolution(
            executableURL: executableURL,
            environment: environment,
            shellProbeOutcome: shell.outcome
        )
    }

    public static func resolvedEnvironment(shellPath: String?, baseEnvironment: [String: String]) -> [String: String] {
        var environment = baseEnvironment
        environment["PATH"] = resolvedPath(shellPath: shellPath, basePath: baseEnvironment["PATH"])
        return environment
    }

    public static func resolvedPath(shellPath: String?, basePath: String?) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fallbacks = [
            "\(home)/.local/share/fnm/aliases/default/bin", "\(home)/.volta/bin",
            "\(home)/.local/bin", "\(home)/.cargo/bin", "/opt/homebrew/bin",
            "/opt/homebrew/sbin", "/usr/local/bin", "/System/Cryptexes/App/usr/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin", "/Applications/Codex.app/Contents/Resources",
        ]
        return deduplicated(pathSegments(shellPath) + pathSegments(basePath) + fallbacks).joined(separator: ":")
    }

    static func requiresNode(_ executableURL: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: executableURL) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 512), !data.isEmpty else { return false }
        let magic = [UInt8](data.prefix(4))
        let machOMagics: Set<[UInt8]> = [
            [0xFE, 0xED, 0xFA, 0xCE], [0xCE, 0xFA, 0xED, 0xFE],
            [0xFE, 0xED, 0xFA, 0xCF], [0xCF, 0xFA, 0xED, 0xFE],
            [0xCA, 0xFE, 0xBA, 0xBE], [0xBE, 0xBA, 0xFE, 0xCA],
        ]
        if machOMagics.contains(magic) { return false }
        guard let firstLine = String(data: data, encoding: .utf8)?.split(separator: "\n", maxSplits: 1).first else { return false }
        return firstLine.hasPrefix("#!") && firstLine.localizedCaseInsensitiveContains("node")
    }

    private static func shellResolution(timeout: TimeInterval) -> ShellResolution {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", """
        printf 'PATH=%s\n' "$PATH"
        printf 'CODEX=%s\n' "$(command -v codex 2>/dev/null || true)"
        printf 'NODE=%s\n' "$(command -v node 2>/dev/null || true)"
        """]
        process.standardOutput = stdout
        process.standardError = Pipe()

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return ShellResolution(path: "", codexPath: nil, nodePath: nil, outcome: .launchFailed(error.localizedDescription))
        }

        let outcome: CodexShellProbeOutcome
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 0.2) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            outcome = .timedOut
        } else {
            outcome = process.terminationStatus == 0 ? .success : .exited(process.terminationStatus)
        }

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var fields: [String: String] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator])
            guard key == "PATH" || key == "CODEX" || key == "NODE" else { continue }
            fields[key] = String(line[line.index(after: separator)...])
        }
        return ShellResolution(
            path: fields["PATH"] ?? "",
            codexPath: nonEmpty(fields["CODEX"]),
            nodePath: nonEmpty(fields["NODE"]),
            outcome: outcome
        )
    }

    private static func executableURL(shellPath: String?, environmentPath: String?) -> URL? {
        candidateURLs(shellPath: shellPath, executableName: "codex", fallbackURLs: [
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"), URL(fileURLWithPath: "/usr/local/bin/codex"),
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
        ], environmentPath: environmentPath).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    private static func nodeURL(shellPath: String?, environmentPath: String?) -> URL? {
        candidateURLs(shellPath: shellPath, executableName: "node", fallbackURLs: [
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".volta/bin/node"),
            URL(fileURLWithPath: "/opt/homebrew/bin/node"), URL(fileURLWithPath: "/usr/local/bin/node"),
        ], environmentPath: environmentPath).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    private static func candidateURLs(shellPath: String?, executableName: String, fallbackURLs: [URL], environmentPath: String?) -> [URL] {
        let shellURLs = nonEmpty(shellPath).map { [URL(fileURLWithPath: $0)] } ?? []
        return shellURLs + fallbackURLs + pathSegments(environmentPath).map { URL(fileURLWithPath: $0).appending(path: executableName) }
    }

    private static func pathSegments(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        return value.split(separator: ":").map(String.init).filter { !$0.isEmpty }
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
