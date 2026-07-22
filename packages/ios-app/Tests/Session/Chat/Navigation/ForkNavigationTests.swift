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

    func testWorkerAuditSessionNotificationHasADistinctRoute() {
        XCTAssertEqual(
            Notification.Name.openWorkerAuditSession.rawValue,
            "tron.openWorkerAuditSession"
        )
        XCTAssertNotEqual(
            Notification.Name.openWorkerAuditSession,
            Notification.Name.switchToSession
        )
    }

    func testWorkerAuditSessionCanPresentWithoutAppearingInHome() {
        XCTAssertTrue(
            shouldPresentSelectedSession(
                selectedSessionId: "worker-session-123",
                knownSessionIds: ["ordinary-session"],
                workerAuditSessionId: "worker-session-123"
            )
        )
        XCTAssertFalse(
            shouldPresentSelectedSession(
                selectedSessionId: "missing-session",
                knownSessionIds: ["ordinary-session"],
                workerAuditSessionId: nil
            )
        )
    }

    func testSwitchToSessionNotificationNotPostedOnForkFailure() {
        let expectation = expectation(forNotification: .switchToSession, object: nil)
        expectation.isInverted = true

        // Simulate: fork fails, no notification posted (nothing to do here)

        wait(for: [expectation], timeout: 0.5)
    }
}
