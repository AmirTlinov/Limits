import AppKit
import CryptoKit
import LimitsCore
import XCTest

final class LimitsUITests: XCTestCase {
    @MainActor
    func testIsolatedLayoutCreatesAndReadsOnlyInsideTestRoot() async throws {
        let fileManager = FileManager.default
        let isolatedRoot = fileManager.temporaryDirectory.appending(path: "limits-ui-test-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: isolatedRoot) }
        try await writeCodexFixture(to: isolatedRoot, accountCount: 1)
        let stateDirectory = isolatedRoot.appending(path: "Application Support/Limits")
        for suffix in ["", "-wal", "-shm"] {
            try? fileManager.removeItem(
                at: URL(fileURLWithPath: stateDirectory.appending(path: "usage.sqlite3").path + suffix)
            )
        }

        let app = XCUIApplication()
        app.launchEnvironment["LIMITS_UI_TEST"] = "1"
        app.launchEnvironment["LIMITS_TEST_ROOT"] = isolatedRoot.path
        app.launchEnvironment["LIMITS_DISABLE_EXTERNAL_PROBES"] = "1"
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["codex.insights.overview"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Demo Codex"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.debugDescription.localizedCaseInsensitiveContains("Claude"))

        app.terminate()
        XCTAssertEqual(try firstCodexAccount(in: isolatedRoot)["label"] as? String, "Demo Codex")
        XCTAssertTrue(fileManager.fileExists(atPath: stateDirectory.appending(path: "usage.sqlite3").path))
        XCTAssertTrue(
            fileManager.fileExists(
                atPath: isolatedRoot.appending(path: "AppGroup/Widget/current-limits.json").path
            )
        )
    }

    @MainActor
    func testTrayShowsSavedAccountsWhenContentBecomesScrollable() async throws {
        let fileManager = FileManager.default
        let isolatedRoot = fileManager.temporaryDirectory.appending(path: "limits-ui-scroll-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: isolatedRoot) }
        try await writeCodexFixture(to: isolatedRoot, accountCount: 6)

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
        let tray = app.dialogs.firstMatch
        XCTAssertTrue(tray.waitForExistence(timeout: 3))
        XCTAssertTrue(tray.staticTexts["Demo Codex 1"].waitForExistence(timeout: 3))
        let accountScroll = tray.scrollViews.firstMatch
        XCTAssertTrue(accountScroll.waitForExistence(timeout: 3))
        let lastAccount = tray.staticTexts["Demo Codex 6"]
        for _ in 0..<3 where !lastAccount.exists {
            accountScroll.swipeUp()
        }
        XCTAssertTrue(lastAccount.waitForExistence(timeout: 3))
        app.terminate()
    }

    @MainActor
    func testAccountDetailsShowExactChatGPTTierAndConfirmedPaidPeriod() async throws {
        let fileManager = FileManager.default
        let isolatedRoot = fileManager.temporaryDirectory.appending(path: "limits-ui-subscription-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: isolatedRoot) }
        try await writeCodexFixture(to: isolatedRoot, accountCount: 1)
        let fixtureAccount = try firstCodexAccount(in: isolatedRoot)
        let accountID = try XCTUnwrap((fixtureAccount["id"] as? String).flatMap(UUID.init(uuidString:)))

        let app = XCUIApplication()
        app.launchEnvironment["LIMITS_UI_TEST"] = "1"
        app.launchEnvironment["LIMITS_TEST_ROOT"] = isolatedRoot.path
        app.launchEnvironment["LIMITS_DISABLE_EXTERNAL_PROBES"] = "1"
        app.launchEnvironment["LIMITS_TEST_ACCOUNTS_SELECTION"] = "account:\(accountID.uuidString)"
        app.launchArguments += [
            "-limits.language.override", "en",
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
        let detail = app.scrollViews["accounts.detail.scroll"]
        XCTAssertTrue(detail.waitForExistence(timeout: 3))
        detail.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.02)).click()

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
    func testFutureUsageSchemaDisablesAccountMutationsBeforeInteraction() async throws {
        let fileManager = FileManager.default
        let isolatedRoot = fileManager.temporaryDirectory.appending(path: "limits-ui-read-only-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: isolatedRoot) }
        try await writeCodexFixture(to: isolatedRoot, accountCount: 1)
        let fixtureAccount = try firstCodexAccount(in: isolatedRoot)
        let accountID = try XCTUnwrap((fixtureAccount["id"] as? String).flatMap(UUID.init(uuidString:)))
        let database = isolatedRoot.appending(path: "Application Support/Limits/usage.sqlite3")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, "PRAGMA user_version = 999;"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let app = XCUIApplication()
        app.launchEnvironment["LIMITS_UI_TEST"] = "1"
        app.launchEnvironment["LIMITS_TEST_ROOT"] = isolatedRoot.path
        app.launchEnvironment["LIMITS_DISABLE_EXTERNAL_PROBES"] = "1"
        app.launchEnvironment["LIMITS_TEST_ACCOUNTS_SELECTION"] = "account:\(accountID.uuidString)"
        app.launchArguments += ["-limits.language.override", "en"]
        app.launch()
        app.activate()

        let title = app.staticTexts["account.identity.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        let accountActions = app.buttons["account.actions.more"]
        XCTAssertTrue(accountActions.waitForExistence(timeout: 3))
        XCTAssertFalse(accountActions.isEnabled)
        title.doubleClick()
        XCTAssertFalse(app.textFields["account.identity.name-field"].waitForExistence(timeout: 1))
        app.terminate()
    }

    @MainActor
    func testCodexOverviewShowsActivityWithoutRedundantRiskOrAccountBlocks() async throws {
        let fileManager = FileManager.default
        let isolatedRoot = fileManager.temporaryDirectory.appending(path: "limits-ui-insights-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: isolatedRoot) }
        try await writeCodexFixture(to: isolatedRoot, accountCount: 2)

        let app = XCUIApplication()
        app.launchEnvironment["LIMITS_UI_TEST"] = "1"
        app.launchEnvironment["LIMITS_TEST_ROOT"] = isolatedRoot.path
        app.launchEnvironment["LIMITS_DISABLE_EXTERNAL_PROBES"] = "1"
        app.launchEnvironment["LIMITS_TEST_ACCOUNTS_SELECTION"] = "codex-overview"
        app.launchArguments += [
            "-limits.language.override", "en",
        ]
        app.launch()
        app.activate()

        XCTAssertTrue(app.descendants(matching: .any)["codex.insights.overview"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["codex.insights.metric.tokens"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["codex.insights.metric.credits"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["codex.insights.metric.api-equivalent"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["codex.insights.models"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["codex.insights.trend"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["codex.insights.activity-calendar"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["codex.insights.period"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["codex.insights.activity-calendar-period"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["codex.insights.work"].exists)
        XCTAssertTrue(app.staticTexts["Daily tokens"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["codex.insights.weekly-risk"].exists)
        XCTAssertFalse(
            app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "codex.insights.account.")
            ).firstMatch.exists
        )
        XCTAssertFalse(app.debugDescription.localizedCaseInsensitiveContains("Claude"))
        XCTAssertFalse(app.buttons["Refresh"].exists)
        app.terminate()
    }

    @MainActor
    func testTrayShowsTheSameCurrentAccountForecast() async throws {
        let fileManager = FileManager.default
        let isolatedRoot = fileManager.temporaryDirectory.appending(path: "limits-ui-tray-forecast-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: isolatedRoot) }
        try await writeCodexFixture(to: isolatedRoot, accountCount: 1)

        let app = XCUIApplication()
        app.launchEnvironment["LIMITS_UI_TEST"] = "1"
        app.launchEnvironment["LIMITS_TEST_ROOT"] = isolatedRoot.path
        app.launchEnvironment["LIMITS_DISABLE_EXTERNAL_PROBES"] = "1"
        app.launchArguments += ["-limits.language.override", "en"]
        app.launch()
        app.activate()

        let statusItem = app.menuBars.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 8))
        statusItem.click()
        if !app.dialogs.firstMatch.waitForExistence(timeout: 3) {
            app.activate()
            statusItem.click()
        }
        XCTAssertTrue(app.dialogs.firstMatch.waitForExistence(timeout: 3))
        let forecast = app.descendants(matching: .any)["codex.tray.forecast"]
        XCTAssertTrue(forecast.waitForExistence(timeout: 3))
        XCTAssertTrue(forecast.label.contains("Collecting pace") || ((forecast.value as? String)?.contains("Collecting pace") == true))
        app.terminate()
    }

    @MainActor
    func testOverviewExplainsOneConfirmedPriceChangeWithoutANotification() async throws {
        let fileManager = FileManager.default
        let isolatedRoot = fileManager.temporaryDirectory.appending(path: "limits-ui-price-change-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: isolatedRoot) }
        try await writeCodexFixture(to: isolatedRoot, accountCount: 1)
        try writePricingChangeFixture(to: isolatedRoot)

        let app = XCUIApplication()
        app.launchEnvironment["LIMITS_UI_TEST"] = "1"
        app.launchEnvironment["LIMITS_TEST_ROOT"] = isolatedRoot.path
        app.launchEnvironment["LIMITS_DISABLE_EXTERNAL_PROBES"] = "1"
        app.launchEnvironment["LIMITS_TEST_ACCOUNTS_SELECTION"] = "codex-overview"
        app.launchArguments += ["-limits.language.override", "en"]
        app.launch()
        app.activate()

        let notice = app.descendants(matching: .any)["codex.insights.price-change"]
        XCTAssertTrue(notice.waitForExistence(timeout: 8))
        let text = (notice.value as? String) ?? notice.label
        XCTAssertTrue(text.contains("Sol"))
        XCTAssertTrue(text.contains("input credits"))
        XCTAssertTrue(text.contains("125"))
        XCTAssertTrue(text.contains("250"))
        XCTAssertTrue(text.contains("100%"))
        app.terminate()
    }

    @MainActor
    func testRevokedLimitTokenShowsOneHumanIssueWithoutServerPayload() async throws {
        let fileManager = FileManager.default
        let isolatedRoot = fileManager.temporaryDirectory.appending(path: "limits-ui-account-issue-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: isolatedRoot) }
        try await writeCodexFixture(to: isolatedRoot, accountCount: 1, limitsIssue: "authorizationExpired")
        let fixtureAccount = try firstCodexAccount(in: isolatedRoot)
        let accountID = try XCTUnwrap((fixtureAccount["id"] as? String).flatMap(UUID.init(uuidString:)))

        let app = XCUIApplication()
        app.launchEnvironment["LIMITS_UI_TEST"] = "1"
        app.launchEnvironment["LIMITS_TEST_ROOT"] = isolatedRoot.path
        app.launchEnvironment["LIMITS_DISABLE_EXTERNAL_PROBES"] = "1"
        app.launchEnvironment["LIMITS_TEST_ACCOUNTS_SELECTION"] = "account:\(accountID.uuidString)"
        app.launchArguments += [
            "-limits.language.override", "en",
        ]
        app.launch()
        app.activate()

        let issue = app.otherElements["codex.account.issue"]
        XCTAssertTrue(issue.waitForExistence(timeout: 3))
        XCTAssertEqual(issue.label, "Sign-in expired. Sign in again to restore limits for this account.")
        XCTAssertEqual(app.otherElements.matching(identifier: "codex.account.issue").count, 1)
        XCTAssertTrue(app.buttons["Sign in again"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Make Current"].exists)
        XCTAssertFalse(app.buttons["Refresh"].exists)
        XCTAssertFalse(app.buttons["Refresh values"].exists)
        XCTAssertFalse(app.buttons["Refresh current values"].exists)

        let statusItem = app.menuBars.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 3))
        statusItem.click()
        let panel = app.dialogs.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        let trayIssue = panel.staticTexts["codex.tray.forecast"]
        XCTAssertTrue(trayIssue.waitForExistence(timeout: 3))
        XCTAssertEqual((trayIssue.value as? String) ?? trayIssue.label, "Sign-in expired")
        XCTAssertFalse(app.debugDescription.contains("backend-api/wham/usage"))
        XCTAssertFalse(app.debugDescription.contains("token_revoked"))
        app.terminate()
    }

    @MainActor
    func testCaptureDocumentationScreenshots() async throws {
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
        try await writeCodexFixture(to: isolatedRoot, accountCount: 2)

        let lightApp = documentationApp(root: isolatedRoot, colorScheme: "light")
        lightApp.launch()
        lightApp.activate()
        XCTAssertTrue(lightApp.descendants(matching: .any)["codex.insights.overview"].waitForExistence(timeout: 8))
        XCTAssertTrue(lightApp.descendants(matching: .any)["codex.insights.models"].waitForExistence(timeout: 3))
        let lightWindow = lightApp.windows.firstMatch
        XCTAssertTrue(lightWindow.waitForExistence(timeout: 8))
        let windowAttachment = XCTAttachment(screenshot: lightWindow.screenshot())
        windowAttachment.name = "limits-window.png"
        windowAttachment.lifetime = .keepAlways
        add(windowAttachment)

        let detailScroll = lightApp.scrollViews["accounts.detail.scroll"]
        XCTAssertTrue(detailScroll.waitForExistence(timeout: 3))
        detailScroll.swipeUp()
        let activityAttachment = XCTAttachment(screenshot: lightWindow.screenshot())
        activityAttachment.name = "limits-window-activity.png"
        activityAttachment.lifetime = .keepAlways
        add(activityAttachment)

        let statusItem = lightApp.menuBars.statusItems.firstMatch
        if statusItem.waitForExistence(timeout: 3) {
            statusItem.click()
            let panel = lightApp.dialogs.firstMatch
            XCTAssertTrue(panel.waitForExistence(timeout: 3))
            let trayAttachment = XCTAttachment(screenshot: panel.screenshot())
            trayAttachment.name = "limits-tray.png"
            trayAttachment.lifetime = .keepAlways
            add(trayAttachment)
        } else {
            throw XCTSkip("The runner did not expose the menu bar status item.")
        }
        lightApp.terminate()

        let darkApp = documentationApp(root: isolatedRoot, colorScheme: "dark")
        darkApp.launch()
        darkApp.activate()
        XCTAssertTrue(darkApp.descendants(matching: .any)["codex.insights.overview"].waitForExistence(timeout: 8))
        XCTAssertTrue(darkApp.descendants(matching: .any)["codex.insights.models"].waitForExistence(timeout: 3))
        let darkWindow = darkApp.windows.firstMatch
        XCTAssertTrue(darkWindow.waitForExistence(timeout: 8))
        let darkAttachment = XCTAttachment(screenshot: darkWindow.screenshot())
        darkAttachment.name = "limits-window-dark.png"
        darkAttachment.lifetime = .keepAlways
        add(darkAttachment)
        darkApp.terminate()
    }

    @MainActor
    private func documentationApp(root: URL, colorScheme: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LIMITS_UI_TEST"] = "1"
        app.launchEnvironment["LIMITS_TEST_ROOT"] = root.path
        app.launchEnvironment["LIMITS_DISABLE_EXTERNAL_PROBES"] = "1"
        app.launchEnvironment["LIMITS_TEST_ACCOUNTS_SELECTION"] = "codex-overview"
        app.launchEnvironment["LIMITS_TEST_COLOR_SCHEME"] = colorScheme
        app.launchArguments += ["-limits.language.override", "en"]
        return app
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
        field.typeKey(.rightArrow, modifierFlags: .command)
        let maximumDeletions = ((field.value as? String)?.count ?? 0) + 3
        for _ in 0..<maximumDeletions {
            guard (field.value as? String)?.isEmpty == false else { break }
            field.typeKey(.delete, modifierFlags: [])
        }
        XCTAssertEqual(field.value as? String, "")
        field.typeText(value)
    }

    @MainActor
    private func writeCodexFixture(to root: URL, accountCount: Int, limitsIssue: String? = nil) async throws {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        let currentAuthData = Data("{\"auth_mode\":\"chatgpt\",\"tokens\":{\"account_id\":\"fixture-account-1\"}}".utf8)
        let currentFingerprint = SHA256.hash(data: currentAuthData).map { String(format: "%02x", $0) }.joined()
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
                "authFingerprint": index == 1 ? currentFingerprint : "fixture-fingerprint-\(index)",
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
        let codexDirectory = root.appending(path: "Codex", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try currentAuthData.write(to: codexDirectory.appending(path: "auth.json"), options: .atomic)
        let usageRepository = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: stateDirectory))
        _ = try await usageRepository.open()
        try await usageRepository.recordCurrentAuthIdentity(
            accountID: "fixture-account-1",
            fingerprint: currentFingerprint,
            observedAt: now.addingTimeInterval(-2 * 60 * 60),
            transition: .exact
        )
        await usageRepository.close()
        try writeNumericRolloutFixture(to: root, now: now)
    }

    private func writeNumericRolloutFixture(to root: URL, now: Date) throws {
        let formatter = ISO8601DateFormatter()
        let directory = root.appending(path: "Codex/sessions/2026/08/21", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lines = [
            ["timestamp": formatter.string(from: now.addingTimeInterval(-3_600)), "type": "session_meta", "payload": ["id": "fixture-thread", "cwd": "/Users/fixture/Limits", "git": ["repository_url": "https://github.com/AmirTlinov/Limits.git"]]],
            ["timestamp": formatter.string(from: now.addingTimeInterval(-3_550)), "type": "event_msg", "payload": ["type": "user_message", "message": "Repair the analytics overview"]],
            ["timestamp": formatter.string(from: now.addingTimeInterval(-3_500)), "type": "turn_context", "payload": ["turn_id": "fixture-turn-1", "model": "gpt-5.6-sol", "effort": "high"]],
            ["timestamp": formatter.string(from: now.addingTimeInterval(-3_000)), "type": "event_msg", "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": 2_000_000, "cached_input_tokens": 1_000_000, "cache_write_input_tokens": 100_000, "output_tokens": 100_000, "reasoning_output_tokens": 70_000, "total_tokens": 2_100_000]]]],
            ["timestamp": formatter.string(from: now.addingTimeInterval(-2_900)), "type": "turn_context", "payload": ["turn_id": "fixture-turn-2", "model": "gpt-5.6-terra", "effort": "medium"]],
            ["timestamp": formatter.string(from: now.addingTimeInterval(-2_400)), "type": "event_msg", "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": 2_450_000, "cached_input_tokens": 1_200_000, "cache_write_input_tokens": 100_000, "output_tokens": 150_000, "reasoning_output_tokens": 90_000, "total_tokens": 2_600_000]]]],
            ["timestamp": formatter.string(from: now.addingTimeInterval(-2_300)), "type": "event_msg", "payload": ["type": "task_complete"]],
        ] as [[String: Any]]
        let data = try lines.reduce(into: Data()) { output, line in
            output.append(try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]))
            output.append(0x0A)
        }
        try data.write(to: directory.appending(path: "fixture.jsonl"), options: .atomic)
    }

    private func writePricingChangeFixture(to root: URL) throws {
        let directory = root.appending(path: "Pricing", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let chatGPT = """
        # Pricing
        <table>
          <thead><tr><th>Credits per 1M tokens</th><th>Input Tokens</th><th>Cached input tokens</th><th>Output Tokens</th></tr></thead>
          <tbody>
            <tr><td>GPT-5.6 Sol</td><td>250 credits</td><td>12.5 credits</td><td>750 credits</td></tr>
            <tr><td>GPT-5.6 Terra</td><td>50 credits</td><td>5 credits</td><td>300 credits</td></tr>
            <tr><td>GPT-5.6 Luna</td><td>5 credits</td><td>0.5 credits</td><td>30 credits</td></tr>
            <tr><td>GPT-5.5</td><td>125 credits</td><td>12.5 credits</td><td>750 credits</td></tr>
            <tr><td>GPT-5.4</td><td>62.5 credits</td><td>6.25 credits</td><td>375 credits</td></tr>
            <tr><td>GPT-5.4 mini</td><td>18.75 credits</td><td>1.875 credits</td><td>113 credits</td></tr>
          </tbody>
        </table>
        """
        let header = "| Model | Short context input | Short context cached input | Short context cache writes | Short context output | Long context input | Long context cached input | Long context cache writes | Long context output |"
        let separator = "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"
        let standard = [
            "| gpt-5.6-sol | $5.00 | $0.50 | $6.25 | $30.00 | $10.00 | $1.00 | $12.50 | $45.00 |",
            "| gpt-5.6-terra | $2.00 | $0.20 | $2.50 | $12.00 | $4.00 | $0.40 | $5.00 | $18.00 |",
            "| gpt-5.6-luna | $0.20 | $0.02 | $0.25 | $1.20 | $0.40 | $0.04 | $0.50 | $1.80 |",
            "| gpt-5.5 (<272K context length) | $5.00 | $0.50 | - | $30.00 | $10.00 | $1.00 | - | $45.00 |",
            "| gpt-5.4 (<272K context length) | $2.50 | $0.25 | - | $15.00 | $5.00 | $0.50 | - | $22.50 |",
            "| gpt-5.4-mini | $0.75 | $0.075 | - | $4.50 | - | - | - | - |",
        ]
        let fast = [
            "| gpt-5.6-sol | $10.00 | $1.00 | $12.50 | $60.00 | $20.00 | $2.00 | $25.00 | $90.00 |",
            "| gpt-5.6-terra | $4.00 | $0.40 | $5.00 | $24.00 | $8.00 | $0.80 | $10.00 | $36.00 |",
            "| gpt-5.6-luna | $0.40 | $0.04 | $0.50 | $2.40 | $0.80 | $0.08 | $1.00 | $3.60 |",
            "| gpt-5.5 (<272K context length) | $12.50 | $1.25 | - | $75.00 | - | - | - | - |",
            "| gpt-5.4 (<272K context length) | $5.00 | $0.50 | - | $30.00 | - | - | - | - |",
            "| gpt-5.4-mini | $1.50 | $0.15 | - | $9.00 | - | - | - | - |",
        ]
        let api = (["# Pricing", "### Standard pricing data", header, separator] + standard
            + ["", "### Fast pricing data", header, separator] + fast).joined(separator: "\n")
        let speed = """
        # Speed
        GPT-5.6 and GPT-5.5 consume credits at 2.5x the Standard rate;
        GPT-5.4 consumes credits at 2x the Standard rate.
        """
        try chatGPT.write(to: directory.appending(path: "chatgpt.md"), atomically: true, encoding: .utf8)
        try api.write(to: directory.appending(path: "api.md"), atomically: true, encoding: .utf8)
        try speed.write(to: directory.appending(path: "speed.md"), atomically: true, encoding: .utf8)
    }
}
