import XCTest
@testable import TronMobile

final class LocalChatNotificationTests: XCTestCase {
    func testLocalErrorNotificationCarriesDetailsWithoutPersistenceClaim() {
        let notification = LocalChatNotification.error(
            dedupKey: "attachment.error",
            title: "Could not attach file",
            message: "Permission denied",
            suggestion: "Choose a readable file."
        )

        XCTAssertEqual(notification.dedupKey, "attachment.error")
        XCTAssertEqual(notification.severity, .error)
        XCTAssertEqual(notification.textContent, "Could not attach file: Permission denied")
        XCTAssertEqual(notification.detail, .error(title: "Could not attach file", message: "Permission denied", suggestion: "Choose a readable file."))
    }

    func testMessageContentMarksLocalNotificationAsNotification() {
        let notification = LocalChatNotification.error(
            dedupKey: "model.switch",
            title: "Could not switch model",
            message: "Unavailable"
        )
        let content = MessageContent.localNotification(notification)

        XCTAssertTrue(content.isNotification)
        XCTAssertEqual(content.textContent, "Could not switch model: Unavailable")
        XCTAssertNil(content.asSystemEvent)
    }
}
