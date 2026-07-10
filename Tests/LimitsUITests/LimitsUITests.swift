import XCTest

@MainActor
final class LimitsUITests: XCTestCase {
    func testFirstLaunchPresentsClosableMainWindow() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-limits.completedFirstLaunch.v1", "false",
        ]
        app.launch()

        let mainWindow = app.windows.matching(identifier: "accounts").firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))
        XCTAssertTrue(mainWindow.splitGroups.firstMatch.exists)
        app.terminate()
    }
}
