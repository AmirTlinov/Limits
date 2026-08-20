import XCTest

final class LimitsUITests: XCTestCase {
    @MainActor
    func testNoClaudeFixtureContainsNoClaudeSurfaceAndLeavesProductionFilesUntouched() throws {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let productionState = home.appending(path: "Library/Application Support/Limits/state.json")
        let productionAuth = home.appending(path: ".codex/auth.json")
        let stateBefore = try dataIfPresent(productionState)
        let authBefore = try dataIfPresent(productionAuth)
        let isolatedRoot = fileManager.temporaryDirectory.appending(path: "limits-ui-test-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: isolatedRoot) }

        let app = XCUIApplication()
        app.launchEnvironment["LIMITS_UI_TEST"] = "1"
        app.launchEnvironment["LIMITS_TEST_ROOT"] = isolatedRoot.path
        app.launchEnvironment["LIMITS_DISABLE_EXTERNAL_PROBES"] = "1"
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Codex CLI"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.debugDescription.localizedCaseInsensitiveContains("Claude"))

        app.terminate()
        XCTAssertEqual(try dataIfPresent(productionState), stateBefore)
        XCTAssertEqual(try dataIfPresent(productionAuth), authBefore)
        XCTAssertTrue(fileManager.fileExists(atPath: isolatedRoot.appending(path: "Application Support/Limits").path))
    }

    @MainActor
    func testTrayShowsSavedAccountsWhenContentBecomesScrollable() throws {
        let fileManager = FileManager.default
        let isolatedRoot = fileManager.temporaryDirectory.appending(path: "limits-ui-scroll-(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: isolatedRoot) }
        try writeCodexFixture(to: isolatedRoot, accountCount: 6)

        let app = XCUIApplication()
        app.launchEnvironment["LIMITS_UI_TEST"] = "1"
        app.launchEnvironment["LIMITS_TEST_ROOT"] = isolatedRoot.path
        app.launchEnvironment["LIMITS_DISABLE_EXTERNAL_PROBES"] = "1"
        app.launchArguments += [
            "-limits.tray.codex.expanded", "YES",
            "-limits.tray.provider.filter", "all",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["Demo Codex 1"].waitForExistence(timeout: 8))
        let statusItem = app.menuBars.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 3))
        statusItem.click()
        XCTAssertTrue(app.dialogs.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Codex CLI"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Demo Codex 1"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Demo Codex 6"].waitForExistence(timeout: 3))
        app.terminate()
    }

    @MainActor
    func testCaptureDocumentationScreenshots() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let requestURL = repositoryRoot.appending(path: ".build/documentation-screenshot-output")
        guard FileManager.default.fileExists(atPath: requestURL.path) else {
            throw XCTSkip("Documentation screenshot output was not requested.")
        }
        let isolatedRoot = FileManager.default.temporaryDirectory.appending(path: "limits-screenshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: isolatedRoot) }
        try writeCodexFixture(to: isolatedRoot, accountCount: 1)

        let app = XCUIApplication()
        app.launchEnvironment["LIMITS_UI_TEST"] = "1"
        app.launchEnvironment["LIMITS_TEST_ROOT"] = isolatedRoot.path
        app.launchEnvironment["LIMITS_DISABLE_EXTERNAL_PROBES"] = "1"
        app.launch()
        app.activate()
        XCTAssertTrue(app.staticTexts["Demo Codex"].waitForExistence(timeout: 8))
        app.staticTexts["Demo Codex"].firstMatch.click()
        let window = app.windows.containing(.staticText, identifier: "Demo Codex").firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        let windowAttachment = XCTAttachment(screenshot: window.screenshot())
        windowAttachment.name = "limits-window.png"
        windowAttachment.lifetime = .keepAlways
        add(windowAttachment)

        let statusItem = app.menuBars.statusItems.firstMatch
        if statusItem.waitForExistence(timeout: 3) {
            statusItem.click()
            let panel = app.dialogs.firstMatch
            XCTAssertTrue(panel.waitForExistence(timeout: 3))
            let trayAttachment = XCTAttachment(screenshot: panel.screenshot())
            trayAttachment.name = "limits-tray.png"
            trayAttachment.lifetime = .keepAlways
            add(trayAttachment)
        } else {
            throw XCTSkip("The runner did not expose the menu bar status item.")
        }
        app.terminate()
    }

    private func dataIfPresent(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private func writeCodexFixture(to root: URL, accountCount: Int) throws {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        let stateDirectory = root.appending(path: "Application Support/Limits")
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let accounts: [[String: Any]] = (1...accountCount).map { index in
            let label = accountCount == 1 ? "Demo Codex" : "Demo Codex \(index)"
            return [
                "id": UUID().uuidString,
                "label": label,
                "email": "demo\(index)@example.com",
                "accountId": "fixture-account-\(index)",
                "planType": "pro",
                "createdAt": formatter.string(from: now.addingTimeInterval(-86_400)),
                "updatedAt": formatter.string(from: now),
                "lastValidatedAt": formatter.string(from: now),
                "status": "ok",
                "lastRateLimit": [
                    "limitId": "codex",
                    "planType": "pro",
                    "primary": [
                        "resetsAt": Int(now.addingTimeInterval(3_600).timeIntervalSince1970),
                        "usedPercent": 36,
                        "windowDurationMins": 300,
                    ],
                    "secondary": [
                        "resetsAt": Int(now.addingTimeInterval(3 * 86_400).timeIntervalSince1970),
                        "usedPercent": 19,
                        "windowDurationMins": 10_080,
                    ],
                ],
                "authFingerprint": "fixture-fingerprint-\(index)",
                "keychainAccount": "fixture-keychain-reference-\(index)",
            ]
        }
        let state: [String: Any] = [
            "schemaVersion": 3,
            "revision": 1,
            "accounts": accounts,
            "claudeAccounts": [],
            "retiredCredentials": [],
        ]
        let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: stateDirectory.appending(path: "state.json"), options: .atomic)
    }
}
