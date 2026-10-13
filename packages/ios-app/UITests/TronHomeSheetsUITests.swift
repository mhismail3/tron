import XCTest

/// Manage Home and every sub-sheet, walked end to end on the hosted Home fixture.
/// Each step keeps a large-detent screenshot so a reviewer can compare the sheets.
final class TronHomeSheetsUITests: XCTestCase {
    @MainActor
    func testHomeSheetsTour() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        let ring = app.buttons["session-context-button"]
        XCTAssertTrue(ring.waitForExistence(timeout: 10))
        XCTAssertTrue(waitFor(ring, "label CONTAINS 'Manage Home'"))
        XCTAssertTrue(waitFor(ring, "enabled == true"))
        ring.tap()
        XCTAssertTrue(element(app, "home-manage-state").waitForExistence(timeout: 5), app.debugDescription)
        expand(app, done: "home-sheet-done-manage")
        keep("01-manage")
        app.swipeUp()
        XCTAssertTrue(element(app, "home-manage-settings").waitForExistence(timeout: 3))
        keep("01b-manage-bottom")
        app.swipeDown()

        open(app, "home-manage-context", ready: "home-context-breakdown")
        expand(app, done: "home-sheet-done-context")
        keep("02-context")
        app.buttons["home-sheet-done-context"].tap()

        open(app, "home-manage-memory-browser", ready: "home-memory-row-39")
        expand(app, done: "home-sheet-done-memory")
        keep("03-memory")
        open(app, "home-memory-row-39", ready: "home-memory-detail")
        keep("04-memory-item")
        app.buttons["home-sheet-done-memory-item"].tap()
        app.buttons["home-sheet-done-memory"].tap()

        open(app, "home-manage-chapters", ready: "home-chapter-1")
        expand(app, done: "home-sheet-done-chapters")
        keep("05-chapters")
        open(app, "home-chapter-1", ready: "home-chapter-detail")
        expand(app, done: "home-sheet-done-chapter")
        keep("06-chapter-sealed")
        open(app, "home-chapter-browse-memory", ready: "home-memory-summary-28-4")
        expand(app, done: "home-sheet-done-memory")
        keep("07-chapter-memory")
        open(app, "home-memory-summary-24-4", ready: "home-memory-summary-detail")
        expand(app, done: "home-sheet-done-memory-summary")
        keep("07b-memory-summary")
        app.buttons["home-sheet-done-memory-summary"].tap()
        app.buttons["home-sheet-done-memory"].tap()
        app.buttons["home-sheet-done-chapter"].tap()
        app.buttons["home-sheet-done-chapters"].tap()

        open(app, "home-manage-tasks", ready: "home-task-active")
        expand(app, done: "home-sheet-done-tasks")
        keep("08-tasks")
        open(app, "home-task-active", ready: "home-task-detail")
        expand(app, done: "home-sheet-done-task")
        keep("09-task-detail")
    }

    // MARK: - Helpers

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @MainActor private func open(_ app: XCUIApplication, _ id: String, ready: String) {
        let row = element(app, id)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(id)\n\(app.debugDescription)")
        row.tap()
        XCTAssertTrue(element(app, ready).waitForExistence(timeout: 8), "\(ready)\n\(app.debugDescription)")
    }

    /// Drags the top sheet by its navigation bar (beside the title, never over content)
    /// so it settles at its large detent; its Done button names the sheet.
    @MainActor private func expand(_ app: XCUIApplication, done id: String) {
        let done = app.buttons[id]
        XCTAssertTrue(done.waitForExistence(timeout: 5), id)
        guard done.frame.minY > 120 else { return }
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: 60, dy: done.frame.midY))
            .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: 60, dy: 20)))
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "frame.minY < 120"), object: done)], timeout: 3)
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
