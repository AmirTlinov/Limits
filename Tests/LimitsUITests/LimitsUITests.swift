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

        let mainWindow = app.windows["Limits"]
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))
        XCTAssertTrue(app.splitGroups.firstMatch.exists)
        app.terminate()
    }
}
