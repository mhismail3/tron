import XCTest

/// The session terminal sheet against the hosted Home fixture.
final class TronSessionTerminalUITests: XCTestCase {
    /// #479: a terminal the Gateway closed shows its reason on the existing
    /// Recent terminals item, and its replay ends with the same line.
    @MainActor
    func testClosedTerminalShowsGatewayReason() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-terminal-closed"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        let ring = app.buttons["session-context-button"]
        XCTAssertTrue(ring.waitForExistence(timeout: 10), app.debugDescription)
        wait(for: ring, "isEnabled == true AND label CONTAINS 'Manage Home'")
        ring.tap()
        let terminal = app.buttons["manage-home-terminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 5), app.debugDescription)
        terminal.tap()
        let options = app.buttons["Terminal options"]
        XCTAssertTrue(options.waitForExistence(timeout: 5), app.debugDescription)
        options.tap()
        let closed = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Closed after 60 minutes idle")).firstMatch
        XCTAssertTrue(closed.waitForExistence(timeout: 5), app.debugDescription)
        // No other notice covers the menu (a failed fixture read would raise one).
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Gateway response")).firstMatch.exists)
        keepScreenshot(named: "terminal-recent-closed-reason")
        closed.tap()
        XCTAssertFalse(app.staticTexts["Terminal unavailable"].waitForExistence(timeout: 2))
        keepScreenshot(named: "terminal-closed-replay-reason")
    }

    @MainActor
    private func wait(for element: XCUIElement, _ predicate: String) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed, element.debugDescription)
    }

    @MainActor
    private func keepScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
