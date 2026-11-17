import XCTest

@MainActor final class TronSheetLayoutUITests: XCTestCase {
    func testHistoryEntryUsesOneScrollAndClearsToolbarAtMedium() {
        let app = history()
        defer { app.terminate() }
        let title = app.navigationBars.staticTexts["History Entry"].firstMatch
        let done = app.navigationBars.containing(.staticText, identifier: "History Entry").buttons["Done"].firstMatch
        let response = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Response'")).firstMatch
        XCTAssertTrue(response.exists, app.debugDescription)
        XCTAssertGreaterThan(title.frame.minY, app.windows.firstMatch.frame.height * 0.35, "Exercise the medium detent")
        XCTAssertGreaterThanOrEqual(response.frame.minY, done.frame.maxY, "The top card must not overlap the toolbar")
        let reader = app.scrollViews.matching(NSPredicate(format: "identifier == 'history-entry-scroll'")).firstMatch
        XCTAssertTrue(reader.exists, "One sheet-level reader owns scrolling")
        XCTAssertEqual(reader.scrollViews.count, 0, "No nested scroll view")
        XCTAssertEqual(reader.textViews.count, 0, "No independently scrolling UITextView")
        let actions = app.descendants(matching: .any)["history-entry-actions"].firstMatch
        let initialY = response.frame.minY
        reader.swipeUp()
        XCTAssertLessThan(response.frame.minY, initialY, "The top card and content flow together")
        XCTAssertTrue(actions.exists, "Actions remain in the sheet")
    }

    private func home(dark: Bool = false, xxxl: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-settings-scope-review"] + (dark ? ["-home-dark"] : [])
        if xxxl { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"] }
        app.launch()
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 15))
        app.buttons["home-pinned-row"].tap()
        let ring = app.buttons["session-context-button"]
        XCTAssertTrue(ring.waitForExistence(timeout: 15))
        XCTAssertTrue(wait(ring, "enabled == true"))
        ring.tap()
        let row = app.descendants(matching: .any)["home-manage-settings"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), app.debugDescription)
        reveal(row, in: app)
        row.tap()
        expand(app, title: "Home Settings")
        return app
    }

    private func session(dark: Bool = false, xxxl: Bool = false) -> XCUIApplication {
        let app = sessionApp(dark: dark, xxxl: xxxl)
        let link = app.buttons["chat-settings-link"]
        reveal(link, in: app)
        link.tap()
        expand(app, title: "Session Settings")
        return app
    }

    private func history(dark: Bool = false) -> XCUIApplication {
        let app = sessionApp(dark: dark, extra: ["-manage-session-review", "-history-large"])
        let link = app.buttons["Session History"]
        reveal(link, in: app)
        link.tap()
        XCTAssertTrue(app.buttons["history-row-h-6732"].waitForExistence(timeout: 10), app.debugDescription)
        expand(app, title: "Session History")
        app.buttons["history-row-h-6731"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["History Entry"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ENDSWITH ' characters'")).firstMatch.waitForExistence(timeout: 8), app.debugDescription)
        return app
    }

    private func sessionApp(dark: Bool, xxxl: Bool = false, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-configuration-fixture", "-settings-scope-review", "-fixture-appearance", dark ? "dark" : "light"] + extra
        if xxxl { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"] }
        app.launch()
        XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 10))
        app.buttons["Stop session"].tap()
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 {
            let laidOut = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !element.exists || !element.frame.isEmpty }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [laidOut], timeout: 10), .completed, app.debugDescription)
            if element.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }

    private func expand(_ app: XCUIApplication, title text: String) {
        let title = app.navigationBars.staticTexts[text].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 8), app.debugDescription)
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        for _ in 0..<3 where title.frame.minY > 120 {
            origin.withOffset(CGVector(dx: 60, dy: title.frame.midY))
                .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: 60, dy: 20)))
            _ = wait(title, "frame.minY < 120", timeout: 2)
        }
    }

    private func wait(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 10) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)], timeout: timeout) == .completed
    }

}
