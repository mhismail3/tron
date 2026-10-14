import XCTest

/// The Home dashboard view (#973) on the hosted Home fixture: the usage card,
/// Home's running, recently completed and unread workers from its task
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
        // Unread is every settled unread session; the ordinary chat among them
        // is listed in its View more sheet (testUnreadCapsAtFiveWithViewMore).
        XCTAssertTrue(app.buttons["session-row-home-shell-fixture:worker-unread-1"].waitForExistence(timeout: 5), app.debugDescription)
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

    /// #982: the view's sections fade in once, in stagger order, while the usage
    /// card holds the shared pulse at its final height; its rows then fade in
    /// without a layout jump, and a live new worker re-fades nothing.
    @MainActor
    func testSectionsRevealInOrderAndLiveUpdatesDoNotRefade() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-dashboard-workers", "-dashboard-view-home",
                               "-home-dashboard-usage-delay", "-home-dashboard-new-worker", "-home-dashboard-new-worker-late"]
        app.launch(); defer { app.terminate() }

        let card = element(app, "home-usage-card")
        let reveals = app.staticTexts["fixture.dashboard-reveals"]
        XCTAssertTrue(card.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(waitFor(card, "label == 'Loading account usage'"), card.label)
        // The card (order 0), In Progress (1) and Recently Completed (2) reveal
        // while the card still shows its pulse.
        XCTAssertTrue(waitFor(reveals, "label BEGINSWITH 'orders:0,1,2'"), reveals.label)
        XCTAssertEqual(card.label, "Loading account usage", "The usage read is still in flight")
        let inProgress = app.staticTexts["In Progress"], completed = app.staticTexts["Recently Completed"]
        XCTAssertTrue(inProgress.exists && completed.exists, app.debugDescription)
        XCTAssertLessThan(card.frame.maxY, inProgress.frame.minY)
        XCTAssertLessThan(inProgress.frame.minY, completed.frame.minY)
        let loadingHeight = card.frame.height
        keep("05-usage-loading")

        // Loader to content at the same height.
        XCTAssertTrue(waitFor(card, "label BEGINSWITH 'Anthropic, 42%'"), card.label)
        XCTAssertEqual(card.frame.height, loadingHeight, accuracy: 1, "The card keeps its height when usage arrives")
        let settled = reveals.label
        keep("06-usage-content")

        // A live catalog update inserts its row without re-revealing anything.
        let newWorker = app.buttons["session-row-home-shell-fixture:worker-new"]
        XCTAssertFalse(newWorker.exists)
        XCTAssertTrue(newWorker.waitForExistence(timeout: 10), app.debugDescription)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(reveals.label, settled, "Refreshes never re-fade existing content")
        XCTAssertTrue(card.label.hasPrefix("Anthropic, 42%"), "Refreshes keep the usage content")
    }

    /// Tapping the usage card opens the Filter-style providers sheet; a hidden
    /// provider leaves the card and returns when shown again, and with every
    /// provider hidden the card keeps a compact row that reopens the sheet.
    @MainActor
    func testUsageCardChoosesItsProviders() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-dashboard-workers", "-dashboard-view-home"]
        app.launch(); defer { app.terminate() }

        let card = element(app, "home-usage-card")
        XCTAssertTrue(card.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(waitFor(card, "label CONTAINS 'Anthropic, ' AND label CONTAINS 'OpenAI Codex, '"), card.label)
        card.tap()
        let anthropic = app.buttons["home-usage-provider-anthropic"], codex = app.buttons["home-usage-provider-openai-codex"]
        XCTAssertTrue(anthropic.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.navigationBars["Usage Providers"].exists || app.staticTexts["Usage Providers"].exists, app.debugDescription)
        // Only providers with usage support are listed.
        XCTAssertFalse(app.buttons["home-usage-provider-fixture"].exists)
        XCTAssertEqual(anthropic.value as? String, "Selected")
        keep("07-usage-providers-sheet")

        anthropic.tap()
        XCTAssertTrue(waitFor(anthropic, "value == 'Not selected'"), app.debugDescription)
        XCTAssertTrue(waitFor(card, "NOT (label CONTAINS 'Anthropic') AND label CONTAINS 'OpenAI Codex, '"), card.label)
        codex.tap()
        XCTAssertTrue(waitFor(card, "label == 'Usage, no providers shown'"), card.label)
        app.buttons["Done"].tap()
        XCTAssertTrue(waitFor(anthropic, "exists == false"), app.debugDescription)
        keep("08-usage-card-all-hidden")

        // The compact row reopens the sheet; showing a provider restores it.
        card.tap()
        XCTAssertTrue(anthropic.waitForExistence(timeout: 5), app.debugDescription)
        anthropic.tap()
        XCTAssertTrue(waitFor(card, "label BEGINSWITH 'Anthropic, ' AND NOT (label CONTAINS 'OpenAI Codex')"), card.label)
        codex.tap()
        XCTAssertTrue(waitFor(card, "label CONTAINS 'Anthropic, ' AND label CONTAINS 'OpenAI Codex, '"), card.label)
    }

    /// Unread shows five rows, then View more opens the shared section sheet
    /// listing every unread session.
    @MainActor
    func testUnreadCapsAtFiveWithViewMore() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-dashboard-workers", "-dashboard-view-home"]
        app.launch(); defer { app.terminate() }

        XCTAssertTrue(element(app, "home-usage-card").waitForExistence(timeout: 30), app.debugDescription)
        let viewMore = element(app, "home-unread-view-more")
        for _ in 0..<4 where !viewMore.isHittable { app.swipeUp() }
        XCTAssertTrue(viewMore.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Unread · 6"].exists, app.debugDescription)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Unviewed'")).firstMatch.exists)
        let unreadIDs = ["worker-unread-1", "worker-unread-2", "worker-unread-3", "worker-unread-4", "worker-unread-5", "chat-unread"]
        let shown = unreadIDs.filter { app.buttons["session-row-home-shell-fixture:\($0)"].exists }
        XCTAssertEqual(shown, Array(unreadIDs.prefix(5)), "Unread shows its first five rows")
        keep("09-unread-capped")

        viewMore.tap()
        for id in unreadIDs {
            XCTAssertTrue(app.buttons["home-unread-sheet-row-home-shell-fixture:\(id)"].waitForExistence(timeout: 5), app.debugDescription)
        }
        XCTAssertFalse(app.buttons["home-unread-sheet-row-home-shell-fixture:worker-done-1"].exists)
        keep("10-unread-sheet")
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
