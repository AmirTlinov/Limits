import Foundation
import Testing
@testable import LimitsCore

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
    try Data("{\"five_hour\":{}}".utf8).write(to: service.snapshotURL)

    let status = try service.bridgeStatus()
    #expect(status.installed)
    #expect(status.preservingOriginalStatusLine)

    try service.uninstallBridge()

    let restoredSettingsData = try Data(contentsOf: settingsURL)
    let restoredSettings = try #require(JSONSerialization.jsonObject(with: restoredSettingsData) as? [String: Any])
    let restoredStatusLine = try #require(restoredSettings["statusLine"] as? [String: Any])
    #expect(restoredStatusLine["command"] as? String == "echo original-statusline")
    #expect(!FileManager.default.fileExists(atPath: service.snapshotURL.path))
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
    #expect(!FileManager.default.fileExists(atPath: service.scriptURL.path))
    #expect(!FileManager.default.fileExists(atPath: service.originalStatusLineBackupURL.path))
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
      "five_hour": {
        "used_percentage": 23.5,
        "resets_at": 1738425600
      },
      "seven_day": {
        "used_percentage": 41.2,
        "resets_at": 1738857600
      }
    }
    """

    try snapshotJSON.data(using: .utf8)!.write(to: service.snapshotURL, options: .atomic)
    let payload = try service.readSnapshot()

    #expect(payload.snapshot.fiveHour?.usedPercentage == 23.5)
    #expect(payload.snapshot.sevenDay?.usedPercentage == 41.2)
}

@Test func claudeBridgeScriptPersistsOnlyRateLimitWindowsWithSystemPlutil() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "limits-claude-script-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ClaudeStatuslineBridgeService(
        homeDirectory: root.appending(path: "home"),
        appSupportDirectory: root.appending(path: "support")
    )
    try service.installBridge()

    let input = Data("""
    {
      "session_id":"secret-session",
      "cwd":"/private/workspace",
      "transcript_path":"/private/transcript.jsonl",
      "rate_limits":{
        "five_hour":{"used_percentage":12,"resets_at":2000000},
        "seven_day":{"used_percentage":34,"resets_at":2100000}
      }
    }
    """.utf8)
    let process = Process()
    let stdin = Pipe()
    process.executableURL = service.scriptURL
    process.standardInput = stdin
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    try stdin.fileHandleForWriting.write(contentsOf: input)
    try stdin.fileHandleForWriting.close()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)

    let data = try Data(contentsOf: service.snapshotURL)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(object.keys) == ["five_hour", "seven_day"])
    let text = String(decoding: data, as: UTF8.self)
    #expect(!text.contains("session_id"))
    #expect(!text.contains("cwd"))
    #expect(!text.contains("transcript"))
    let script = try String(contentsOf: service.scriptURL, encoding: .utf8)
    #expect(!script.contains(".input."))
    let persistedNames = try FileManager.default.contentsOfDirectory(atPath: service.appSupportDirectory.path)
    #expect(!persistedNames.contains { $0.contains("input") })
}

@Test func claudeBridgeScriptKeepsTheLastReadingWhenAPayloadCarriesNoRateLimits() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "limits-claude-empty-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ClaudeStatuslineBridgeService(
        homeDirectory: root.appending(path: "home"),
        appSupportDirectory: root.appending(path: "support")
    )
    try service.installBridge()

    func run(_ payload: String) throws {
        let process = Process()
        let stdin = Pipe()
        process.executableURL = service.scriptURL
        process.standardInput = stdin
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: Data(payload.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    try run(#"{"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":2000000}}}"#)
    let stored = try Data(contentsOf: service.snapshotURL)

    // Claude Code fires the status line on session start before any turn has produced limits.
    try run(#"{"session_id":"fresh-session","rate_limits":null}"#)
    try run(#"{"session_id":"fresh-session"}"#)

    let after = try Data(contentsOf: service.snapshotURL)
    #expect(after == stored)
    let object = try #require(JSONSerialization.jsonObject(with: after) as? [String: Any])
    #expect(Set(object.keys) == ["five_hour"])
}

private func bridgePermissions(at url: URL) -> Int {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

@Test func claudeBridgeUpgradesAScriptWrittenByAnOlderBuild() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "limits-claude-upgrade-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ClaudeStatuslineBridgeService(
        homeDirectory: root.appending(path: "home"),
        appSupportDirectory: root.appending(path: "support")
    )
    try service.installBridge()
    #expect(service.bridgeScriptIsCurrent())
    #expect(try service.upgradeBridgeScriptIfNeeded() == false)

    // Stand in for an install made before the current snapshot shape shipped.
    let stale = "#!/bin/zsh\n# limits-statusline-bridge v1\nexit 0\n"
    try stale.write(to: service.scriptURL, atomically: true, encoding: .utf8)
    #expect(service.bridgeScriptIsCurrent() == false)

    // installBridge() only runs when the user connects the bridge, so a shipped script
    // change reaches an existing install through the upgrade path alone.
    #expect(try service.upgradeBridgeScriptIfNeeded())
    #expect(service.bridgeScriptIsCurrent())
    let script = try String(contentsOf: service.scriptURL, encoding: .utf8)
    #expect(script.contains("seven_day_opus"))
    #expect(bridgePermissions(at: service.scriptURL) == 0o700)

    // Nothing to do when the bridge was never installed.
    let bare = ClaudeStatuslineBridgeService(
        homeDirectory: root.appending(path: "home2"),
        appSupportDirectory: root.appending(path: "support2")
    )
    #expect(try bare.upgradeBridgeScriptIfNeeded() == false)
}
