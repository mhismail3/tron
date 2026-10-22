import XCTest

/// A row that opens a managed sub-sheet always opens it, and the sheet haptic
/// plays once per presentation that actually happens, never for a request
/// UIKit has not presented (#1695). The fixture drives the shared presenters
/// with requests a finger cannot time; Manage Home › Profile covers the
/// production rows.
final class TronSubsheetReliabilityUITests: XCTestCase {
    /// Requesting the parent's other presenter while a child covers it is
    /// deferred by UIKit until the child leaves: silent until it appears, then
    /// exactly one impact.
    @MainActor func testDeferredPresentationPlaysWhenItAppears() {
        continueAfterFailure = false
        let app = launchFixture(); defer { app.terminate() }
        let title = app.staticTexts["fixture.child-title"]
        app.buttons["fixture.row-a"].tap()
        XCTAssertTrue(waitFor(title, "label == 'Item a'"))
        assertSheetHaptics(app, 2, "parent and item")
        app.buttons["fixture.request-sibling"].tap()
        XCTAssertTrue(waitFor(app.staticTexts["fixture.child-state"], "label == 'item:a flag:true'"))
        assertSheetHaptics(app, 2, "a request UIKit has not presented plays nothing")
        XCTAssertEqual(title.label, "Item a")
        app.buttons["fixture.child-close"].tap()
        XCTAssertTrue(waitFor(title, "label == 'Flag'"), app.debugDescription)
        assertSheetHaptics(app, 3, "the deferred sheet plays once it appears")
    }

    /// A request that is torn down before it ever appears plays nothing and
    /// reports `managed-sheet.never-appeared`.
    @MainActor func testRequestThatNeverAppearsIsSilentAndReported() {
        continueAfterFailure = false
        let app = launchFixture(); defer { app.terminate() }
        let title = app.staticTexts["fixture.child-title"]
        app.buttons["fixture.row-a"].tap()
        XCTAssertTrue(waitFor(title, "label == 'Item a'"))
        assertSheetHaptics(app, 2, "parent and item")
        app.buttons["fixture.request-sibling-close-parent"].tap()
        XCTAssertTrue(app.buttons["fixture.open-parent"].waitForExistence(timeout: 10))
        XCTAssertTrue(title.waitForNonExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(waitFor(app.staticTexts["fixture.never-appeared"], "label == 'never-appeared:1'"),
                      app.staticTexts["fixture.never-appeared"].label)
        assertSheetHaptics(app, 2, "a request that never appeared plays nothing", probe: "fixture.root-sheet-haptics")
        // The presenters are not left holding the stale request.
        app.buttons["fixture.open-parent"].tap()
        app.buttons["fixture.flag-row"].tap()
        XCTAssertTrue(waitFor(title, "label == 'Flag'"), app.debugDescription)
        assertSheetHaptics(app, 4, "parent and flag")
    }

    /// Re-requesting a child 0–700 ms into its dismissal, for the item and the
    /// Boolean presenter, always presents it with exactly one impact.
    @MainActor func testRequestDuringDismissalAlwaysPresentsOnce() {
        continueAfterFailure = false
        let app = launchFixture(); defer { app.terminate() }
        let title = app.staticTexts["fixture.child-title"]
        var played = 1
        for (row, reopened) in [("fixture.row-a", "Item b"), ("fixture.flag-row", "Flag")] {
            for delay in [0, 150, 300, 450, 700] {
                app.buttons[row].tap()
                XCTAssertTrue(title.waitForExistence(timeout: 8), "\(row) \(delay)")
                played += 1
                assertSheetHaptics(app, played, "\(row) opened")
                app.buttons["fixture.rerequest-\(delay)"].tap()
                XCTAssertTrue(waitFor(title, "label == '\(reopened)'"), "\(row) re-requested after \(delay) ms: \(app.debugDescription)")
                played += 1
                assertSheetHaptics(app, played, "\(row) re-requested after \(delay) ms")
                app.buttons["fixture.child-close"].tap()
                XCTAssertTrue(title.waitForNonExistence(timeout: 8), "\(row) \(delay) close")
            }
        }
    }

    /// Manage Home › Profile: every item row reopens its sheet after a button
    /// close, an interactive swipe and a background/foreground cycle, with one
    /// impact per presentation.
    @MainActor func testProfileRowsReopenAfterEveryDismissal() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        let ring = app.buttons["session-context-button"]
        XCTAssertTrue(waitFor(ring, "enabled == true"))
        ring.tap()
        let profileRow = element(app, "home-manage-profile")
        XCTAssertTrue(profileRow.waitForExistence(timeout: 8), app.debugDescription)
        profileRow.tap()
        XCTAssertTrue(element(app, "home-profile-group-preference").waitForExistence(timeout: 8), app.debugDescription)
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'home-profile-item-'"))
        let ids = Array(rows.allElementsBoundByIndex.map(\.identifier).filter { !$0.contains("detail") }.prefix(2))
        XCTAssertEqual(ids.count, 2)
        let feedback = app.staticTexts["fixture.sheet-feedback"]
        var played = 2 // Manage Home and Profile
        XCTAssertTrue(waitFor(feedback, "label == 'sheet-feedback:\(played)'"), feedback.label)
        let detail = element(app, "home-profile-item-detail")
        let window = app.windows.firstMatch
        for (index, dismissal) in ["done", "swipe", "background", "done", "swipe", "background"].enumerated() {
            element(app, ids[index % 2]).tap()
            XCTAssertTrue(detail.waitForExistence(timeout: 8), "\(index) after \(dismissal): \(app.debugDescription)")
            played += 1
            XCTAssertTrue(waitFor(feedback, "label == 'sheet-feedback:\(played)'"), "\(index): \(feedback.label)")
            switch dismissal {
            case "swipe":
                window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62))
                    .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.0)),
                           withVelocity: .fast, thenHoldForDuration: 0)
            case "background":
                XCUIDevice.shared.press(.home)
                XCTAssertTrue(app.wait(for: .runningBackground, timeout: 15))
                app.activate()
                XCTAssertTrue(detail.waitForExistence(timeout: 10), "the item survives foreground")
                closeTopSheet(app)
            default:
                closeTopSheet(app)
            }
            XCTAssertTrue(detail.waitForNonExistence(timeout: 8), "\(index) \(dismissal) closes")
        }
        XCTAssertEqual(feedback.label, "sheet-feedback:\(played)", "dismissal, swipe and foreground play nothing")
    }

    // MARK: - Helpers

    @MainActor private func launchFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-subsheet-reliability-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["fixture.open-parent"].waitForExistence(timeout: 20))
        app.buttons["fixture.open-parent"].tap()
        XCTAssertTrue(app.buttons["fixture.row-a"].waitForExistence(timeout: 10))
        assertSheetHaptics(app, 1, "the parent")
        return app
    }

    /// Waits for the count, then holds it: no late or duplicate impact.
    @MainActor private func assertSheetHaptics(_ app: XCUIApplication, _ count: Int, _ message: String,
                                               probe id: String = "fixture.sheet-haptics") {
        let probe = app.staticTexts[id]
        XCTAssertTrue(waitFor(probe, "label == 'haptics:\(count)'", timeout: 5), "\(message): \(probe.label)")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(probe.label, "haptics:\(count)", "\(message): no late or duplicate impact")
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @MainActor private func closeTopSheet(_ app: XCUIApplication) {
        let done = app.buttons.matching(NSPredicate(format: "label == 'Done'")).allElementsBoundByIndex.last(where: \.isHittable)
        XCTAssertNotNil(done, app.debugDescription)
        done?.tap()
    }

    private func waitFor(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 10) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)], timeout: timeout) == .completed
    }
}
