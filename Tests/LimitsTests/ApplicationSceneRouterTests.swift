import XCTest
@testable import Limits

@MainActor
final class ApplicationSceneRouterTests: XCTestCase {
    func testAccountsWindowRequestIsConsumedExactlyOnce() {
        let router = ApplicationSceneRouter()

        XCTAssertFalse(router.consumeAccountsWindowRequest())
        router.requestAccountsWindow()
        XCTAssertTrue(router.consumeAccountsWindowRequest())
        XCTAssertFalse(router.consumeAccountsWindowRequest())
    }
}
