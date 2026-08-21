import AppKit
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
        XCTAssertTrue(app.staticTexts["Codex"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.debugDescription.contains("Codex CLI"))
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
        app.activate()

        XCTAssertTrue(app.staticTexts["Demo Codex 1"].waitForExistence(timeout: 8))
        let statusItem = app.menuBars.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 3))
        statusItem.click()
        XCTAssertTrue(app.dialogs.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Codex"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Demo Codex 1"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Demo Codex 6"].waitForExistence(timeout: 3))
        app.terminate()
    }

    @MainActor
    func testAccountDetailsShowExactChatGPTTierAndConfirmedPaidPeriod() throws {
        let fileManager = FileManager.default
        let isolatedRoot = fileManager.temporaryDirectory.appending(path: "limits-ui-subscription-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: isolatedRoot) }
        try writeCodexFixture(to: isolatedRoot, accountCount: 1)
        let fixtureAccount = try firstCodexAccount(in: isolatedRoot)
        let accountID = try XCTUnwrap((fixtureAccount["id"] as? String).flatMap(UUID.init(uuidString:)))

        let app = XCUIApplication()
        app.launchEnvironment["LIMITS_UI_TEST"] = "1"
        app.launchEnvironment["LIMITS_TEST_ROOT"] = isolatedRoot.path
        app.launchEnvironment["LIMITS_DISABLE_EXTERNAL_PROBES"] = "1"
        app.launchArguments += [
            "-limits.language.override", "en",
            "-limits.accounts.selection", "account:\(accountID.uuidString)",
        ]
        app.launch()
        app.activate()

        let title = app.staticTexts["account.identity.title"]
        let email = app.buttons["account.identity.email"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        XCTAssertEqual(title.value as? String, "Demo Codex")
        XCTAssertTrue(email.waitForExistence(timeout: 3))
        XCTAssertEqual(email.label, "demo1@example.com")

        XCTAssertFalse(app.buttons["Refresh"].exists)
        XCTAssertFalse(app.buttons["Refresh values"].exists)
        XCTAssertFalse(app.buttons["Refresh current values"].exists)
        XCTAssertFalse(app.buttons["Sign in again"].exists)

        NSPasteboard.general.clearContents()
        email.click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "demo1@example.com")

        title.doubleClick()
        let nameField = app.textFields["account.identity.name-field"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3))
        replaceText(in: nameField, with: "2042")
        XCTAssertEqual(nameField.value as? String, "2042")
        nameField.typeKey(.return, modifierFlags: [])

        let renamedTitle = app.staticTexts["account.identity.title"]
        XCTAssertTrue(renamedTitle.waitForExistence(timeout: 3))
        XCTAssertTrue(waitForText("2042", on: renamedTitle, timeout: 3))
        XCTAssertEqual(try firstCodexAccount(in: isolatedRoot)["label"] as? String, "2042")

        let plan = app.otherElements["chatgpt.subscription.plan"]
        let cycle = app.otherElements["chatgpt.subscription.cycle"]
        XCTAssertTrue(plan.waitForExistence(timeout: 3))
        XCTAssertEqual(plan.label, "ChatGPT Pro 20×, $200/month")
        XCTAssertTrue(cycle.waitForExistence(timeout: 3))
        XCTAssertTrue(cycle.label.hasPrefix("Until payment:"))
        XCTAssertTrue(cycle.label.contains("Payment / renewal"))
        app.terminate()
    }

    @MainActor
    func testRevokedLimitTokenShowsOneHumanIssueWithoutServerPayload() throws {
        let fileManager = FileManager.default
        let isolatedRoot = fileManager.temporaryDirectory.appending(path: "limits-ui-account-issue-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: isolatedRoot) }
        try writeCodexFixture(to: isolatedRoot, accountCount: 1, limitsIssue: "authorizationExpired")
        let fixtureAccount = try firstCodexAccount(in: isolatedRoot)
        let accountID = try XCTUnwrap((fixtureAccount["id"] as? String).flatMap(UUID.init(uuidString:)))

        let app = XCUIApplication()
        app.launchEnvironment["LIMITS_UI_TEST"] = "1"
        app.launchEnvironment["LIMITS_TEST_ROOT"] = isolatedRoot.path
        app.launchEnvironment["LIMITS_DISABLE_EXTERNAL_PROBES"] = "1"
        app.launchArguments += [
            "-limits.language.override", "en",
            "-limits.accounts.selection", "account:\(accountID.uuidString)",
        ]
        app.launch()
        app.activate()

        let issue = app.otherElements["codex.account.issue"]
        XCTAssertTrue(issue.waitForExistence(timeout: 3))
        XCTAssertEqual(issue.label, "Sign-in expired. Sign in again to restore limits for this account.")
        XCTAssertEqual(app.otherElements.matching(identifier: "codex.account.issue").count, 1)
        XCTAssertTrue(app.buttons["Sign in again"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Refresh"].exists)
        XCTAssertFalse(app.buttons["Refresh values"].exists)
        XCTAssertFalse(app.buttons["Refresh current values"].exists)

        let statusItem = app.menuBars.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 3))
        statusItem.click()
        let panel = app.dialogs.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        let trayAccount = panel.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Sign-in expired")
        ).firstMatch
        XCTAssertTrue(trayAccount.waitForExistence(timeout: 3))
        XCTAssertFalse(app.debugDescription.contains("backend-api/wham/usage"))
        XCTAssertFalse(app.debugDescription.contains("token_revoked"))
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
        let fixtureAccount = try firstCodexAccount(in: isolatedRoot)
        let accountID = try XCTUnwrap((fixtureAccount["id"] as? String).flatMap(UUID.init(uuidString:)))

        let app = XCUIApplication()
        app.launchEnvironment["LIMITS_UI_TEST"] = "1"
        app.launchEnvironment["LIMITS_TEST_ROOT"] = isolatedRoot.path
        app.launchEnvironment["LIMITS_DISABLE_EXTERNAL_PROBES"] = "1"
        app.launchArguments += ["-limits.accounts.selection", "account:\(accountID.uuidString)"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.staticTexts["Demo Codex"].waitForExistence(timeout: 8))
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

    @MainActor
    private func waitForText(_ expected: String, on element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.value as? String == expected || element.label == expected {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return element.value as? String == expected || element.label == expected
    }

    private func firstCodexAccount(in root: URL) throws -> [String: Any] {
        let stateURL = root.appending(path: "Application Support/Limits/state.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL))
        let state = try XCTUnwrap(object as? [String: Any])
        let accounts = try XCTUnwrap(state["accounts"] as? [[String: Any]])
        return try XCTUnwrap(accounts.first)
    }

    @MainActor
    private func replaceText(in field: XCUIElement, with value: String) {
        field.click()
        let existingValue = (field.value as? String) ?? ""
        for _ in 0...existingValue.count {
            field.typeKey(.rightArrow, modifierFlags: [])
        }
        for _ in existingValue {
            field.typeKey(.delete, modifierFlags: [])
        }
        field.typeText(value)
    }

    private func writeCodexFixture(to root: URL, accountCount: Int, limitsIssue: String? = nil) throws {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        let stateDirectory = root.appending(path: "Application Support/Limits")
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let accounts: [[String: Any]] = (1...accountCount).map { index in
            let label = accountCount == 1 ? "Demo Codex" : "Demo Codex \(index)"
            var account: [String: Any] = [
                "id": UUID().uuidString,
                "label": label,
                "email": "demo\(index)@example.com",
                "accountId": "fixture-account-\(index)",
                "planType": "pro",
                "createdAt": formatter.string(from: now.addingTimeInterval(-86_400)),
                "updatedAt": formatter.string(from: now),
                "lastValidatedAt": formatter.string(from: now),
                "lastRateLimitObservedAt": formatter.string(from: now),
                "status": "ok",
                "subscriptionPeriod": [
                    "activeStart": formatter.string(from: now.addingTimeInterval(-14 * 86_400)),
                    "activeUntil": formatter.string(from: now.addingTimeInterval(16 * 86_400)),
                    "lastCheckedAt": formatter.string(from: now),
                ],
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
            if index == 1, let limitsIssue {
                account["limitsIssue"] = limitsIssue
                account["statusMessage"] = "GET https://chatgpt.com/backend-api/wham/usage failed: 401 Unauthorized; token_revoked"
            }
            return account
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
