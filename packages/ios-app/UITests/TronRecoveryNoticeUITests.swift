import XCTest

final class TronRecoveryNoticeUITests: XCTestCase {
    @MainActor
    func testAnIdenticalRecoveryNoticeIsNotPostedAgainAfterItExpires() {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-recovery-notice-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let card = app.descendants(matching: .any).matching(identifier: "in-app-notice-card").firstMatch
        let status = app.buttons["chat-recovery-status"]
        let classify = app.buttons["recovery-notice-classify"]
        XCTAssertTrue(card.waitForExistence(timeout: 60), "the recovery episode never posted its notice: \(app.debugDescription)")
        XCTAssertTrue(card.label.contains("Gateway connection unavailable"), card.label)
        XCTAssertTrue(status.waitForExistence(timeout: 10), "the route never showed its recovery status: \(app.debugDescription)")
        XCTAssertTrue(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Mac unreachable"),
                                                                        object: card)], timeout: 20) == .completed,
                      "the notice never read Mac unreachable before it expired: \(card.label)")
        XCTAssertTrue(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: card)],
                                       timeout: 20) == .completed, "the recovery notice never expired")
        XCTAssertTrue(waitForHittable(status, timeout: 10), "Retry is not reachable after the notice expired: \(app.debugDescription)")
        keep(app.screenshot(), "2273-after-expiry")

        classify.tap()
        XCTAssertFalse(card.waitForExistence(timeout: 3),
                       "an identical recovery notice was posted again over Retry: \(card.label)")
        XCTAssertTrue(status.isHittable, "Retry must stay reachable after a same-text reclassification")
        keep(app.screenshot(), "2273-after-reclassification")
        status.tap()
        XCTAssertTrue(app.staticTexts["Retries 1"].waitForExistence(timeout: 5), "Retry did not receive the tap")
    }

    @MainActor
    func testUnreadableKeychainAtLaunchStaysPairedAndRetriesOnForeground() {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-keychain-locked-fixture", "-tronSetupComplete.v1", "YES",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let state = app.staticTexts["keychain-locked-state"]
        let unreadable = "offline: This iPhone's Keychain cannot be read yet. Unlock it to reconnect."
        XCTAssertTrue(state.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(XCTWaiter().wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", unreadable), object: state)], timeout: 15) == .completed,
                      "an unreadable Keychain did not leave the paired Mac offline: \(state.label)")
        XCTAssertFalse(app.staticTexts["Welcome to Tron"].waitForExistence(timeout: 5),
                       "an unreadable Keychain presented setup for a paired Mac: \(app.debugDescription)")
        keep(app.screenshot(), "2296-keychain-unreadable-launch")

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackgroundSuspended, timeout: 10) || app.state == .runningBackground)
        app.activate()
        XCTAssertTrue(XCTWaiter().wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@ AND label != %@", unreadable, "unpaired"), object: state)],
                                       timeout: 20) == .completed,
                      "the foreground did not read the token and reconnect: \(state.label)")
        XCTAssertFalse(app.staticTexts["Welcome to Tron"].exists, app.debugDescription)
        keep(app.screenshot(), "2296-keychain-readable-after-foreground")
    }

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isHittable { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    private func keep(_ screenshot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
