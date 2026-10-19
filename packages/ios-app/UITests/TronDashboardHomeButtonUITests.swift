import XCTest

/// The Home dashboard's one Tron-branded button (#1461): a tap opens Home,
/// touch and hold opens the dashboard menu and never also opens Home.
final class TronDashboardHomeButtonUITests: XCTestCase {
    @MainActor
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-dashboard-workers",
                               "-dashboard-view-home"] + extra
        app.launch()
        return app
    }

    @MainActor
    func testTapOpensHomeAndHoldOpensMenuLightAndDark() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = launch(appearance == "dark" ? ["-home-dark"] : [])
            defer { app.terminate() }
            let button = app.buttons["dashboard.menu"]
            XCTAssertTrue(button.waitForExistence(timeout: 15), app.debugDescription)
            XCTAssertEqual(button.label, "Home")
            XCTAssertTrue(waitFor(button, "value == 'Ready'"), app.debugDescription)
            XCTAssertFalse(app.buttons["home-floating-button"].exists, "One button, not a separate Home button")
            keep("1461-home-button-\(appearance)-resting")

            button.press(forDuration: 1.2)
            let settings = app.buttons["Settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(app.buttons["New Session"].exists, app.debugDescription)
            keep("1461-home-button-\(appearance)-held-menu")
            XCTAssertFalse(app.textViews["Message input"].exists, "Releasing a hold does not open Home")

            // Dismiss by tapping outside: the menu closes and Home still does not open.
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).tap()
            XCTAssertTrue(settings.waitForNonExistence(timeout: 5), app.debugDescription)
            XCTAssertFalse(app.textViews["Message input"].waitForExistence(timeout: 2), "Dismissing the menu does not open Home")
            keep("1461-home-button-\(appearance)-menu-dismissed")

            button.tap()
            XCTAssertTrue(app.textViews["Message input"].waitForExistence(timeout: 15), app.debugDescription)
            keep("1461-home-button-\(appearance)-tap-opened-home")
        }
    }

    /// The menu keeps every action, including Settings, and opens Settings.
    @MainActor
    func testHeldMenuOpensSettings() {
        continueAfterFailure = false
        let app = launch(); defer { app.terminate() }
        let button = app.buttons["dashboard.menu"]
        XCTAssertTrue(button.waitForExistence(timeout: 15), app.debugDescription)
        button.press(forDuration: 1.2)
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), app.debugDescription)
        settings.tap()
        XCTAssertTrue(app.buttons["settings-link-Model Providers"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.textViews["Message input"].exists)
    }

    /// Working and Waiting morph in place through the shared indicator swap;
    /// frames are sampled across real fixture status changes (ready → working → waiting).
    @MainActor
    func testStatusTransitionsMorphInPlace() {
        continueAfterFailure = false
        let app = launch(["-home-status-cycle"]); defer { app.terminate() }
        let button = app.buttons["dashboard.menu"]
        XCTAssertTrue(button.waitForExistence(timeout: 15), app.debugDescription)
        for (state, name) in [("Working", "working"), ("Waiting for you", "waiting"), ("Ready", "ready")] {
            // Sample frames until the next status lands, then keep the settled state.
            var frames: [XCUIScreenshot] = []
            let deadline = Date().addingTimeInterval(12)
            while Date() < deadline, (button.value as? String) != state {
                frames.append(XCUIScreen.main.screenshot())
            }
            XCTAssertEqual(button.value as? String, state, app.debugDescription)
            for _ in 0..<4 { frames.append(XCUIScreen.main.screenshot()) }
            for (index, frame) in frames.suffix(10).enumerated() {
                let attachment = XCTAttachment(screenshot: frame)
                attachment.name = String(format: "1461-home-transition-to-%@-%02d", name, index)
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            XCTAssertEqual(button.label, "Home")
        }
    }

    private func waitFor(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 10) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)], timeout: timeout) == .completed
    }

    @MainActor private func keep(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
