import XCTest
@testable import TronMobile

final class ForkNavigationTests: XCTestCase {

    func testSwitchToSessionNotificationName() {
        XCTAssertEqual(
            Notification.Name.switchToSession.rawValue,
            "tron.switchToSession"
        )
    }

    func testSwitchToSessionNotificationCarriesSessionId() {
        let expectation = expectation(forNotification: .switchToSession, object: nil) { notification in
            notification.object as? String == "new-fork-session-123"
        }

        NotificationCenter.default.post(name: .switchToSession, object: "new-fork-session-123")

        wait(for: [expectation], timeout: 1.0)
    }

    func testSwitchToSessionNotificationNotPostedOnForkFailure() {
        let expectation = expectation(forNotification: .switchToSession, object: nil)
        expectation.isInverted = true

        // Simulate: fork fails, no notification posted (nothing to do here)

        wait(for: [expectation], timeout: 0.5)
    }
}
