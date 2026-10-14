import XCTest

/// The Home dashboard view (#973) on the hosted Home fixture: the usage card,
/// Home's running, recently completed and unviewed workers from its task
/// ledger, the shared View more sheet, and the floating Home button above the
/// dashboard logo. Screenshots are kept as attachments.
final class TronHomeDashboardUITests: XCTestCase {
    @MainActor
    func testHomeDashboardViewJourney() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-dashboard-workers", "-dashboard-view-home"]
        app.launch(); defer { app.terminate() }

        XCTAssertTrue(element(app, "home-usage-card").waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["session-row-home-shell-fixture:worker-running"].waitForExistence(timeout: 10), app.debugDescription)
        let home = app.buttons["home-floating-button"]
        XCTAssertTrue(home.exists)
        XCTAssertEqual(home.value as? String, "Ready")
        keep("00-home-dashboard")

        // Only Home's workers appear; the ordinary session does not.
        XCTAssertFalse(app.buttons["session-row-home-shell-fixture:ordinary-session"].exists)
        XCTAssertFalse(app.buttons["home-pinned-row"].exists, "The floating button replaces the pinned row")

        app.swipeUp()
        // Unviewed is every settled unread session, including an ordinary chat.
        XCTAssertTrue(app.buttons["session-row-home-shell-fixture:chat-unread"].waitForExistence(timeout: 5), app.debugDescription)
        let viewMore = element(app, "home-completed-view-more")
        XCTAssertTrue(viewMore.waitForExistence(timeout: 5), app.debugDescription)
        keep("01-home-dashboard-scrolled")
        viewMore.tap()
        XCTAssertTrue(app.buttons["home-completed-sheet-row-home-shell-fixture:worker-done-7"].waitForExistence(timeout: 5), app.debugDescription)
        keep("02-recently-completed-sheet")
    }

    /// A worker Home dispatches while the view is open appears in In Progress
    /// as soon as its catalog row arrives, without relaunching.
    @MainActor
    func testNewWorkerAppearsWithoutRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-dashboard-workers", "-dashboard-view-home", "-home-dashboard-new-worker"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["session-row-home-shell-fixture:worker-new"].waitForExistence(timeout: 10), app.debugDescription)
        // Worker identity rides on the synced catalog rows: the view never queries Home's task ledger.
        XCTAssertEqual(app.staticTexts["fixture.home-task-list-reads"].label, "task-list-reads:0")
    }

    @MainActor
    func testHomeButtonShowsWaitingForUser() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-dashboard-workers", "-dashboard-view-home", "-home-phase-active", "-home-waiting"]
        app.launch(); defer { app.terminate() }
        let home = app.buttons["home-floating-button"]
        XCTAssertTrue(home.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(waitFor(home, "value == 'Waiting for you'"), app.debugDescription)
        keep("03-home-button-waiting")
    }

    @MainActor
    func testHomeButtonShowsWorking() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-dashboard-workers", "-dashboard-view-home", "-home-phase-active"]
        app.launch(); defer { app.terminate() }
        let home = app.buttons["home-floating-button"]
        XCTAssertTrue(home.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(waitFor(home, "value == 'Working'"), app.debugDescription)
        keep("04-home-button-working")
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
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
