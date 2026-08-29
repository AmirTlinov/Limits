import Foundation
import LimitsShared

public struct ClaudeStatuslineBridgeSnapshot: Decodable, Hashable, Sendable {
    public struct Window: Decodable, Hashable, Sendable {
        public let usedPercentage: Double?
        public let resetsAt: Int64?

        private enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case resetsAt = "resets_at"
        }

        public init(usedPercentage: Double?, resetsAt: Int64?) {
            self.usedPercentage = usedPercentage
            self.resetsAt = resetsAt
        }
    }

    public let fiveHour: Window?
    public let sevenDay: Window?
    /// Claude Code still names the top-model weekly window `seven_day_opus`; its own settings
    /// screen labels that same allowance after the current top model.
    public let sevenDayTopModel: Window?

    private enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayTopModel = "seven_day_opus"
    }

    public init(fiveHour: Window?, sevenDay: Window?, sevenDayTopModel: Window? = nil) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayTopModel = sevenDayTopModel
    }
}

public struct ClaudeStatuslineBridgePayload: Hashable, Sendable {
    public let snapshot: ClaudeStatuslineBridgeSnapshot
    public let updatedAt: Date

    public init(snapshot: ClaudeStatuslineBridgeSnapshot, updatedAt: Date) {
        self.snapshot = snapshot
        self.updatedAt = updatedAt
    }
}

public struct ClaudeStatuslineBridgeStatus: Hashable, Sendable {
    public let installed: Bool
    public let hasSnapshot: Bool
    public let preservingOriginalStatusLine: Bool

    public init(installed: Bool, hasSnapshot: Bool, preservingOriginalStatusLine: Bool) {
        self.installed = installed
        self.hasSnapshot = hasSnapshot
        self.preservingOriginalStatusLine = preservingOriginalStatusLine
    }
}

public enum ClaudeStatuslineBridgeServiceError: LocalizedError, Equatable {
    case unsupportedExistingStatusLine
    case invalidSettingsShape
    case missingSnapshot
    case settingsChanged

    public var errorDescription: String? {
        switch self {
        case .unsupportedExistingStatusLine:
            return L10n.tr("claude.statusline.unsupported")
        case .invalidSettingsShape:
            return L10n.tr("claude.settings.parse_failed")
        case .missingSnapshot:
            return L10n.tr("claude.statusline.snapshot_missing")
        case .settingsChanged:
            return L10n.tr("claude.settings.changed")
        }
    }
}

struct ClaudeSettingsDocument {
    let data: Data?
    let object: [String: Any]
}

struct ClaudeSettingsDocumentStore {
    let fileManager: FileManager
    let settingsURL: URL

    init(fileManager: FileManager = .default, settingsURL: URL) {
        self.fileManager = fileManager
        self.settingsURL = settingsURL
    }

    func read() throws -> ClaudeSettingsDocument {
        guard fileManager.fileExists(atPath: settingsURL.path) else {
            return ClaudeSettingsDocument(data: nil, object: [:])
        }
        let data = try Data(contentsOf: settingsURL)
        guard !data.isEmpty else {
            return ClaudeSettingsDocument(data: data, object: [:])
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeStatuslineBridgeServiceError.invalidSettingsShape
        }
        return ClaudeSettingsDocument(data: data, object: object)
    }

    func commit(_ object: [String: Any], expectedData: Data?) throws {
        let currentData = fileManager.fileExists(atPath: settingsURL.path)
            ? try Data(contentsOf: settingsURL)
            : nil
        guard currentData == expectedData else {
            throw ClaudeStatuslineBridgeServiceError.settingsChanged
        }

        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: settingsURL.path
        )
    }
}

public struct ClaudeStatuslineBridgeService: @unchecked Sendable {
    private struct StoredOriginalStatusLine: Codable {
        let hadStatusLine: Bool
        let statusLineJSON: String?
    }

    public let fileManager: FileManager
    public let homeDirectory: URL
    public let appSupportDirectory: URL

    public init(
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

    /// Bumped whenever the emitted script changes, so an already-installed bridge is upgraded
    /// instead of silently continuing to write the older snapshot shape.
    static let scriptVersionMarker = "limits-statusline-bridge v2"

    public var scriptURL: URL {
        appSupportDirectory.appending(path: "claude-statusline-bridge.sh")
    }

    public var snapshotURL: URL {
        appSupportDirectory.appending(path: "claude-statusline-snapshot.json")
    }

    public var originalStatusLineBackupURL: URL {
        appSupportDirectory.appending(path: "claude-statusline-original.bin")
    }

    public var claudeSettingsURL: URL {
        homeDirectory
            .appending(path: ".claude", directoryHint: .isDirectory)
            .appending(path: "settings.json")
    }

    public func bridgeStatus() throws -> ClaudeStatuslineBridgeStatus {
        let settings = try settingsStore.read().object
        let installed = isBridgeConfigured(in: settings)
        let hasSnapshot = installed && fileManager.fileExists(atPath: snapshotURL.path)
        let preservingOriginal = try loadOriginalStatusLine()?.hadStatusLine ?? false
        return ClaudeStatuslineBridgeStatus(
            installed: installed,
            hasSnapshot: hasSnapshot,
            preservingOriginalStatusLine: preservingOriginal
        )
    }

    /// Rewrites the installed script when it predates the current snapshot shape. The bridge is
    /// wired into Claude's settings once, so without this an existing install would keep running
    /// the old script and never report the newer windows.
    @discardableResult
    public func upgradeBridgeScriptIfNeeded() throws -> Bool {
        guard try bridgeStatus().installed, !bridgeScriptIsCurrent() else { return false }
        try ensureDirectories()
        try writeBridgeScript()
        return true
    }

    func bridgeScriptIsCurrent() -> Bool {
        guard let script = try? String(contentsOf: scriptURL, encoding: .utf8) else { return false }
        return script.contains(Self.scriptVersionMarker)
    }

    public func installBridge() throws {
        try ensureDirectories()
        let document = try settingsStore.read()
        let scriptExisted = fileManager.fileExists(atPath: scriptURL.path)
        let backupExisted = fileManager.fileExists(atPath: originalStatusLineBackupURL.path)
        do {
            try writeBridgeScript()
            var settings = document.object
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

            try settingsStore.commit(settings, expectedData: document.data)
        } catch {
            if !scriptExisted { try? fileManager.removeItem(at: scriptURL) }
            if !backupExisted { try? fileManager.removeItem(at: originalStatusLineBackupURL) }
            throw error
        }
    }

    public func uninstallBridge() throws {
        let document = try settingsStore.read()
        var settings = document.object
        if isBridgeConfigured(in: settings) {
            if let stored = try loadOriginalStatusLine(), stored.hadStatusLine, let statusLineJSON = stored.statusLineJSON {
                let statusLineData = Data(statusLineJSON.utf8)
                let statusLine = try JSONSerialization.jsonObject(with: statusLineData)
                settings["statusLine"] = statusLine
            } else {
                settings.removeValue(forKey: "statusLine")
            }

            try settingsStore.commit(settings, expectedData: document.data)
        }
        try? fileManager.removeItem(at: snapshotURL)
        try? fileManager.removeItem(at: originalStatusLineBackupURL)
        try? fileManager.removeItem(at: scriptURL)
    }

    public func readSnapshot() throws -> ClaudeStatuslineBridgePayload {
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

    public func clearSnapshot() throws {
        guard fileManager.fileExists(atPath: snapshotURL.path) else { return }
        try fileManager.removeItem(at: snapshotURL)
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(
            at: appSupportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: appSupportDirectory.path)
        try fileManager.createDirectory(at: claudeSettingsURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
    }

    private var settingsStore: ClaudeSettingsDocumentStore {
        ClaudeSettingsDocumentStore(fileManager: fileManager, settingsURL: claudeSettingsURL)
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
        # \(Self.scriptVersionMarker)
        set -euo pipefail
        umask 077

        SNAPSHOT_PATH=\(shellQuoted(snapshotURL.path))
        ORIGINAL_PATH=\(shellQuoted(originalStatusLineBackupURL.path))

        five_path="${SNAPSHOT_PATH}.five.$$"
        seven_path="${SNAPSHOT_PATH}.seven.$$"
        top_path="${SNAPSHOT_PATH}.top.$$"
        plist_path="${SNAPSHOT_PATH}.plist.$$"
        tmp_path="${SNAPSHOT_PATH}.tmp.$$"
        trap 'rm -f -- "$five_path" "$seven_path" "$top_path" "$plist_path" "$tmp_path"' EXIT

        input_json="$(cat)"

        mkdir -p -- \(shellQuoted(appSupportDirectory.path))
        /usr/bin/plutil -create xml1 "$plist_path"
        if printf '%s' "$input_json" | /usr/bin/plutil -extract rate_limits.five_hour json -o "$five_path" - 2>/dev/null; then
          /usr/bin/plutil -insert five_hour -json "$(cat "$five_path")" "$plist_path"
        fi
        if printf '%s' "$input_json" | /usr/bin/plutil -extract rate_limits.seven_day json -o "$seven_path" - 2>/dev/null; then
          /usr/bin/plutil -insert seven_day -json "$(cat "$seven_path")" "$plist_path"
        fi
        if printf '%s' "$input_json" | /usr/bin/plutil -extract rate_limits.seven_day_opus json -o "$top_path" - 2>/dev/null; then
          /usr/bin/plutil -insert seven_day_opus -json "$(cat "$top_path")" "$plist_path"
        fi
        /usr/bin/plutil -convert json -o "$tmp_path" "$plist_path"
        mv "$tmp_path" "$SNAPSHOT_PATH"

        if [[ -f "$ORIGINAL_PATH" ]]; then
          original_json="$(/usr/bin/plutil -extract statusLineJSON raw -o - "$ORIGINAL_PATH" 2>/dev/null || true)"
          original_command=""
          if [[ -n "$original_json" ]]; then
            printf '%s' "$original_json" > "$tmp_path"
            original_command="$(/usr/bin/plutil -extract command raw -o - "$tmp_path" 2>/dev/null || true)"
          fi

          if [[ -n "$original_command" ]]; then
            printf '%s' "$input_json" | /bin/zsh -lc "$original_command"
          fi
        fi
        """

        try content.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
    }

    private func storeOriginalStatusLine(_ payload: StoredOriginalStatusLine) throws {
        let data = try JSONEncoder.limits.encode(payload)
        try data.write(to: originalStatusLineBackupURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: originalStatusLineBackupURL.path)
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
