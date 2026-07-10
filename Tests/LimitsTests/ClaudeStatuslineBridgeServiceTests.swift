import Foundation
import Testing
@testable import Limits

@Test func claudeBridgeInstallAndUninstallPreserveExistingStatusLine() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "limits-claude-bridge-\(UUID().uuidString)", directoryHint: .isDirectory)
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    let appSupport = root.appending(path: "app-support", directoryHint: .isDirectory)
    let settingsDir = home.appending(path: ".claude", directoryHint: .isDirectory)
    let settingsURL = settingsDir.appending(path: "settings.json")

    try FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let originalSettings: [String: Any] = [
        "language": "Russian",
        "statusLine": [
            "type": "command",
            "command": "echo original-statusline",
            "padding": 2,
        ],
    ]
    let originalData = try JSONSerialization.data(withJSONObject: originalSettings, options: [.prettyPrinted, .sortedKeys])
    try originalData.write(to: settingsURL, options: .atomic)

    let service = ClaudeStatuslineBridgeService(homeDirectory: home, appSupportDirectory: appSupport)

    try service.installBridge()

    let installedSettingsData = try Data(contentsOf: settingsURL)
    let installedSettings = try #require(JSONSerialization.jsonObject(with: installedSettingsData) as? [String: Any])
    let installedStatusLine = try #require(installedSettings["statusLine"] as? [String: Any])
    let installedCommand = try #require(installedStatusLine["command"] as? String)

    #expect(installedCommand.contains(service.scriptURL.path))
    #expect(installedStatusLine["padding"] as? Int == 2)
    #expect(FileManager.default.fileExists(atPath: service.scriptURL.path))
    #expect(FileManager.default.fileExists(atPath: service.originalStatusLineBackupURL.path))
    #expect(bridgePermissions(at: appSupport) == 0o700)
    #expect(bridgePermissions(at: service.scriptURL) == 0o700)
    #expect(bridgePermissions(at: service.originalStatusLineBackupURL) == 0o600)
    #expect(bridgePermissions(at: settingsURL) == 0o600)
    #expect(try String(contentsOf: service.scriptURL, encoding: .utf8).contains("umask 077"))

    let status = try service.bridgeStatus()
    #expect(status.installed)
    #expect(status.preservingOriginalStatusLine)

    try service.uninstallBridge()

    let restoredSettingsData = try Data(contentsOf: settingsURL)
    let restoredSettings = try #require(JSONSerialization.jsonObject(with: restoredSettingsData) as? [String: Any])
    let restoredStatusLine = try #require(restoredSettings["statusLine"] as? [String: Any])
    #expect(restoredStatusLine["command"] as? String == "echo original-statusline")
}

@Test func claudeSettingsCommitPreservesConcurrentExternalChange() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "limits-claude-settings-cas-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let settingsURL = root.appending(path: "settings.json")
    let original = Data("{\"language\":\"Russian\"}".utf8)
    let external = Data("{\"language\":\"English\"}".utf8)
    try original.write(to: settingsURL)
    let store = ClaudeSettingsDocumentStore(settingsURL: settingsURL)
    let snapshot = try store.read()
    try external.write(to: settingsURL, options: .atomic)

    do {
        try store.commit(["language": "French"], expectedData: snapshot.data)
        Issue.record("Expected concurrent settings change")
    } catch ClaudeStatuslineBridgeServiceError.settingsChanged {
        // Expected.
    }

    #expect(try Data(contentsOf: settingsURL) == external)
}

@Test func claudeBridgeRejectsUnsupportedExistingStatusLine() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "limits-claude-unsupported-\(UUID().uuidString)", directoryHint: .isDirectory)
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    let appSupport = root.appending(path: "app-support", directoryHint: .isDirectory)
    let settingsDir = home.appending(path: ".claude", directoryHint: .isDirectory)
    let settingsURL = settingsDir.appending(path: "settings.json")

    try FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let originalSettings: [String: Any] = [
        "statusLine": [
            "type": "builtin",
            "theme": "default",
        ],
    ]
    let originalData = try JSONSerialization.data(withJSONObject: originalSettings, options: [.prettyPrinted, .sortedKeys])
    try originalData.write(to: settingsURL, options: .atomic)

    let service = ClaudeStatuslineBridgeService(homeDirectory: home, appSupportDirectory: appSupport)

    do {
        try service.installBridge()
        Issue.record("Ожидалась ошибка unsupportedExistingStatusLine")
    } catch let error as ClaudeStatuslineBridgeServiceError {
        #expect(error == .unsupportedExistingStatusLine)
    }
}

@Test func claudeBridgeReadsSnapshotFromStatusLineJson() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "limits-claude-snapshot-\(UUID().uuidString)", directoryHint: .isDirectory)
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    let appSupport = root.appending(path: "app-support", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let service = ClaudeStatuslineBridgeService(homeDirectory: home, appSupportDirectory: appSupport)
    try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

    let snapshotJSON = """
    {
      "session_id": "session_123",
      "version": "2.1.118",
      "model": {
        "id": "claude-opus-4-7",
        "display_name": "Opus"
      },
      "rate_limits": {
        "five_hour": {
          "used_percentage": 23.5,
          "resets_at": 1738425600
        },
        "seven_day": {
          "used_percentage": 41.2,
          "resets_at": 1738857600
        }
      }
    }
    """

    try snapshotJSON.data(using: .utf8)!.write(to: service.snapshotURL, options: .atomic)
    let payload = try service.readSnapshot()

    #expect(payload.snapshot.sessionID == "session_123")
    #expect(payload.snapshot.rateLimits?.fiveHour?.usedPercentage == 23.5)
    #expect(payload.snapshot.rateLimits?.sevenDay?.usedPercentage == 41.2)
}

private func bridgePermissions(at url: URL) -> Int {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
}
