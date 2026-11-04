import XCTest

/// #2273: within one recovery episode the recovery notice is posted again only when its
/// text changes. A newly classified failure with the same words, after the first notice
/// expired, leaves the title's Retry uncovered instead of posting an identical copy.
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
        // The second never-opened failure reclassifies the episode as Mac unreachable and
        // updates the notice in place; that is the text a later same-class failure repeats.
        XCTAssertTrue(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Mac unreachable"),
                                                                        object: card)], timeout: 20) == .completed,
                      "the notice never read Mac unreachable before it expired: \(card.label)")
        // The notice expires on its own lifetime; the title keeps the lasting reason.
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
