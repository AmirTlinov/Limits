import Foundation

struct ClaudeStatuslineBridgeSnapshot: Decodable, Hashable {
    struct Model: Decodable, Hashable {
        let id: String?
        let displayName: String?

        private enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
        }
    }

    struct RateLimits: Decodable, Hashable {
        struct Window: Decodable, Hashable {
            let usedPercentage: Double?
            let resetsAt: Int64?

            private enum CodingKeys: String, CodingKey {
                case usedPercentage = "used_percentage"
                case resetsAt = "resets_at"
            }
        }

        let fiveHour: Window?
        let sevenDay: Window?

        private enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }

    let sessionID: String?
    let version: String?
    let model: Model?
    let rateLimits: RateLimits?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case version
        case model
        case rateLimits = "rate_limits"
    }
}

struct ClaudeStatuslineBridgePayload: Hashable {
    let snapshot: ClaudeStatuslineBridgeSnapshot
    let updatedAt: Date
}

struct ClaudeStatuslineBridgeStatus: Hashable {
    let installed: Bool
    let hasSnapshot: Bool
    let preservingOriginalStatusLine: Bool
}

enum ClaudeStatuslineBridgeServiceError: LocalizedError, Equatable {
    case unsupportedExistingStatusLine
    case invalidSettingsShape
    case missingSnapshot

    var errorDescription: String? {
        switch self {
        case .unsupportedExistingStatusLine:
            return "У текущего Claude statusLine неподдерживаемый формат. Я не буду молча ломать его."
        case .invalidSettingsShape:
            return "Не удалось разобрать ~/.claude/settings.json."
        case .missingSnapshot:
            return "Claude ещё не прислал снимок statusLine."
        }
    }
}

struct ClaudeStatuslineBridgeService {
    private struct StoredOriginalStatusLine: Codable {
        let hadStatusLine: Bool
        let statusLineJSON: String?
    }

    let fileManager: FileManager
    let homeDirectory: URL
    let appSupportDirectory: URL

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        appSupportDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        if let appSupportDirectory {
            self.appSupportDirectory = appSupportDirectory
        } else {
            let appSupport = try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            self.appSupportDirectory = (appSupport ?? homeDirectory)
                .appending(path: "Limits", directoryHint: .isDirectory)
        }
    }

    var scriptURL: URL {
        appSupportDirectory.appending(path: "claude-statusline-bridge.sh")
    }

    var snapshotURL: URL {
        appSupportDirectory.appending(path: "claude-statusline-snapshot.json")
    }

    var originalStatusLineBackupURL: URL {
        appSupportDirectory.appending(path: "claude-statusline-original.bin")
    }

    var claudeSettingsURL: URL {
        homeDirectory
            .appending(path: ".claude", directoryHint: .isDirectory)
            .appending(path: "settings.json")
    }

    func bridgeStatus() throws -> ClaudeStatuslineBridgeStatus {
        let settings = try readSettingsObject()
        let installed = isBridgeConfigured(in: settings)
        let hasSnapshot = fileManager.fileExists(atPath: snapshotURL.path)
        let preservingOriginal = try loadOriginalStatusLine()?.hadStatusLine ?? false
        return ClaudeStatuslineBridgeStatus(
            installed: installed,
            hasSnapshot: hasSnapshot,
            preservingOriginalStatusLine: preservingOriginal
        )
    }

    func installBridge() throws {
        try ensureDirectories()
        try writeBridgeScript()

        var settings = try readSettingsObject()
        let existingStatusLine = settings["statusLine"]

        if isBridgeConfigured(in: settings) {
            return
        }

        if let existingStatusLine {
            guard JSONSerialization.isValidJSONObject(existingStatusLine) else {
                throw ClaudeStatuslineBridgeServiceError.invalidSettingsShape
            }

            guard
                let object = existingStatusLine as? [String: Any],
                supportsPreserving(statusLineObject: object)
            else {
                throw ClaudeStatuslineBridgeServiceError.unsupportedExistingStatusLine
            }

            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let json = String(decoding: data, as: UTF8.self)
            try storeOriginalStatusLine(StoredOriginalStatusLine(hadStatusLine: true, statusLineJSON: json))

            var bridgeObject = makeBridgeStatusLineObject()
            if let padding = object["padding"] {
                bridgeObject["padding"] = padding
            }
            if let refreshInterval = object["refreshInterval"] {
                bridgeObject["refreshInterval"] = refreshInterval
            }
            settings["statusLine"] = bridgeObject
        } else {
            try storeOriginalStatusLine(StoredOriginalStatusLine(hadStatusLine: false, statusLineJSON: nil))
            settings["statusLine"] = makeBridgeStatusLineObject()
        }

        try writeSettingsObject(settings)
    }

    func uninstallBridge() throws {
        var settings = try readSettingsObject()
        guard isBridgeConfigured(in: settings) else {
            return
        }

        if let stored = try loadOriginalStatusLine(), stored.hadStatusLine, let statusLineJSON = stored.statusLineJSON {
            let statusLineData = Data(statusLineJSON.utf8)
            let statusLine = try JSONSerialization.jsonObject(with: statusLineData)
            settings["statusLine"] = statusLine
        } else {
            settings.removeValue(forKey: "statusLine")
        }

        try writeSettingsObject(settings)
        try? fileManager.removeItem(at: originalStatusLineBackupURL)
        try? fileManager.removeItem(at: scriptURL)
    }

    func readSnapshot() throws -> ClaudeStatuslineBridgePayload {
        guard fileManager.fileExists(atPath: snapshotURL.path) else {
            throw ClaudeStatuslineBridgeServiceError.missingSnapshot
        }

        let data = try Data(contentsOf: snapshotURL)
        let snapshot = try JSONDecoder.limits.decode(ClaudeStatuslineBridgeSnapshot.self, from: data)
        let values = try snapshotURL.resourceValues(forKeys: [.contentModificationDateKey])
        return ClaudeStatuslineBridgePayload(
            snapshot: snapshot,
            updatedAt: values.contentModificationDate ?? .distantPast
        )
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true, attributes: nil)
        try fileManager.createDirectory(at: claudeSettingsURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
    }

    private func readSettingsObject() throws -> [String: Any] {
        guard fileManager.fileExists(atPath: claudeSettingsURL.path) else {
            return [:]
        }

        let data = try Data(contentsOf: claudeSettingsURL)
        if data.isEmpty {
            return [:]
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeStatuslineBridgeServiceError.invalidSettingsShape
        }

        return object
    }

    private func writeSettingsObject(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: claudeSettingsURL, options: .atomic)
    }

    private func makeBridgeStatusLineObject() -> [String: Any] {
        [
            "type": "command",
            "command": shellQuoted(scriptURL.path),
        ]
    }

    private func supportsPreserving(statusLineObject: [String: Any]) -> Bool {
        let type = statusLineObject["type"] as? String ?? "command"
        return type == "command" && statusLineObject["command"] is String
    }

    private func isBridgeConfigured(in settings: [String: Any]) -> Bool {
        guard let statusLine = settings["statusLine"] as? [String: Any] else {
            return false
        }
        guard let command = statusLine["command"] as? String else {
            return false
        }
        return command.contains(scriptURL.path)
    }

    private func writeBridgeScript() throws {
        let content = """
        #!/bin/zsh
        set -euo pipefail

        SNAPSHOT_PATH=\(shellQuoted(snapshotURL.path))
        ORIGINAL_PATH=\(shellQuoted(originalStatusLineBackupURL.path))

        input="$(cat)"

        mkdir -p -- \(shellQuoted(appSupportDirectory.path))
        tmp_path="${SNAPSHOT_PATH}.tmp.$$"
        printf '%s' "$input" > "$tmp_path"
        mv "$tmp_path" "$SNAPSHOT_PATH"

        if [[ -f "$ORIGINAL_PATH" ]]; then
          original_command="$(ORIGINAL_PATH="$ORIGINAL_PATH" /usr/bin/python3 - <<'PY'
        import json
        import os
        import sys

        path = os.environ["ORIGINAL_PATH"]
        try:
            with open(path, "rb") as fh:
                payload = json.load(fh)
            if not payload.get("hadStatusLine"):
                sys.exit(0)
            raw = payload.get("statusLineJSON")
            if raw is None:
                sys.exit(0)
            statusline = json.loads(raw)
            command = statusline.get("command", "")
            if isinstance(command, str):
                sys.stdout.write(command)
        except Exception:
            sys.exit(0)
        PY
          )"

          if [[ -n "$original_command" ]]; then
            printf '%s' "$input" | /bin/zsh -lc "$original_command"
          fi
        fi
        """

        try content.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    private func storeOriginalStatusLine(_ payload: StoredOriginalStatusLine) throws {
        let data = try JSONEncoder.limits.encode(payload)
        try data.write(to: originalStatusLineBackupURL, options: .atomic)
    }

    private func loadOriginalStatusLine() throws -> StoredOriginalStatusLine? {
        guard fileManager.fileExists(atPath: originalStatusLineBackupURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: originalStatusLineBackupURL)
        return try JSONDecoder.limits.decode(StoredOriginalStatusLine.self, from: data)
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}
