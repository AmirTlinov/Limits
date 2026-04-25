import Foundation

enum CodexExecutableLocatorError: LocalizedError {
    case notFound
    case nodeNotFound(codexURL: URL, searchedPath: String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Could not locate the `codex` executable. Install Codex CLI or ensure `command -v codex` works in zsh."
        case .nodeNotFound(let codexURL, let searchedPath):
            return "Could not locate `node` for Codex CLI at \(codexURL.path). Install Node.js or ensure `command -v node` works in zsh. PATH: \(searchedPath)"
        }
    }
}

struct CodexExecutableResolution: Sendable, Equatable {
    let executableURL: URL
    let resolvedNodeURL: URL
    let environment: [String: String]
}

enum CodexExecutableLocator {
    private struct ShellResolution {
        let path: String
        let codexPath: String?
        let nodePath: String?
    }

    static func locate() throws -> CodexExecutableResolution {
        let shell = shellResolution()
        let environment = resolvedEnvironment(shellPath: shell.path, baseEnvironment: ProcessInfo.processInfo.environment)

        guard let executableURL = executableURL(shellPath: shell.codexPath, environmentPath: environment["PATH"]) else {
            throw CodexExecutableLocatorError.notFound
        }

        guard let nodeURL = nodeURL(shellPath: shell.nodePath, environmentPath: environment["PATH"]) else {
            throw CodexExecutableLocatorError.nodeNotFound(codexURL: executableURL, searchedPath: environment["PATH"] ?? "")
        }

        return CodexExecutableResolution(
            executableURL: executableURL,
            resolvedNodeURL: nodeURL,
            environment: environment
        )
    }

    static func resolvedEnvironment(shellPath: String?, baseEnvironment: [String: String]) -> [String: String] {
        var environment = baseEnvironment
        environment["PATH"] = resolvedPath(shellPath: shellPath, basePath: baseEnvironment["PATH"])
        return environment
    }

    static func resolvedPath(shellPath: String?, basePath: String?) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fallbackSegments = [
            "\(home)/.local/state/fnm_multishells",
            "\(home)/.volta/bin",
            "\(home)/.local/bin",
            "\(home)/.cargo/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/System/Cryptexes/App/usr/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "/Applications/Codex.app/Contents/Resources",
        ]

        let directSegments = pathSegments(shellPath) + pathSegments(basePath) + fallbackSegments
        let expandedSegments = directSegments.flatMap { segment -> [String] in
            if segment.hasSuffix("/.local/state/fnm_multishells") {
                return latestExecutableChildDirectories(in: URL(fileURLWithPath: segment)) + [segment]
            }
            return [segment]
        }

        return deduplicated(expandedSegments).joined(separator: ":")
    }

    private static func shellResolution() -> ShellResolution {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-lc",
            """
            printf 'PATH=%s\n' "$PATH"
            printf 'CODEX=%s\n' "$(command -v codex 2>/dev/null || true)"
            printf 'NODE=%s\n' "$(command -v node 2>/dev/null || true)"
            """,
        ]
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return ShellResolution(path: "", codexPath: nil, nodePath: nil)
        }
        process.waitUntilExit()

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let fields = Dictionary(
            uniqueKeysWithValues: output
                .split(separator: "\n", omittingEmptySubsequences: false)
                .compactMap { line -> (String, String)? in
                    guard let separator = line.firstIndex(of: "=") else { return nil }
                    let key = String(line[..<separator])
                    let value = String(line[line.index(after: separator)...])
                    return (key, value)
                }
        )

        return ShellResolution(
            path: fields["PATH"] ?? "",
            codexPath: nonEmpty(fields["CODEX"]),
            nodePath: nonEmpty(fields["NODE"])
        )
    }

    private static func executableURL(shellPath: String?, environmentPath: String?) -> URL? {
        let candidates = candidateURLs(
            shellPath: shellPath,
            executableName: "codex",
            fallbackURLs: [
                FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/codex"),
                URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
                URL(fileURLWithPath: "/usr/local/bin/codex"),
                URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            ],
            environmentPath: environmentPath
        )

        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    private static func nodeURL(shellPath: String?, environmentPath: String?) -> URL? {
        let candidates = candidateURLs(
            shellPath: shellPath,
            executableName: "node",
            fallbackURLs: [
                FileManager.default.homeDirectoryForCurrentUser.appending(path: ".volta/bin/node"),
                URL(fileURLWithPath: "/opt/homebrew/bin/node"),
                URL(fileURLWithPath: "/usr/local/bin/node"),
            ],
            environmentPath: environmentPath
        )

        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    private static func candidateURLs(shellPath: String?, executableName: String, fallbackURLs: [URL], environmentPath: String?) -> [URL] {
        let shellURLs = nonEmpty(shellPath).map { [URL(fileURLWithPath: $0)] } ?? []
        let pathURLs = pathSegments(environmentPath).map { URL(fileURLWithPath: $0).appending(path: executableName) }
        return shellURLs + fallbackURLs + pathURLs
    }

    private static func latestExecutableChildDirectories(in directory: URL) -> [String] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return children
            .filter { url in
                ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
            }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }
            .map(\.path)
    }

    private static func pathSegments(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        return value.split(separator: ":").map(String.init).filter { !$0.isEmpty }
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where !value.isEmpty && !seen.contains(value) {
            seen.insert(value)
            result.append(value)
        }
        return result
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
