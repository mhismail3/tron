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
        expand(app, title: "Manage Home")
        keep("01-manage")

        open(app, "home-manage-context", ready: "home-context-breakdown")
        expand(app, title: "Home Context")
        keep("02-context")
        app.buttons["home-sheet-done-context"].tap()

        open(app, "home-manage-memory-browser", ready: "home-memory-row-39")
        expand(app, title: "Memory")
        keep("03-memory")
        open(app, "home-memory-row-39", ready: "home-memory-detail")
        keep("04-memory-item")
        app.buttons["home-sheet-done-memory-item"].tap()
        app.buttons["home-sheet-done-memory"].tap()

        open(app, "home-manage-chapters", ready: "home-chapter-1")
        expand(app, title: "Chapters")
        keep("05-chapters")
        open(app, "home-chapter-1", ready: "home-chapter-detail")
        expand(app, title: "Chapters")
        keep("06-chapter-sealed")
        open(app, "home-chapter-browse-memory", ready: "home-memory-summary-28-4")
        expand(app, title: "Memory")
        keep("07-chapter-memory")
        open(app, "home-memory-summary-24-4", ready: "home-memory-summary-detail")
        expand(app, title: "Memory")
        keep("07b-memory-summary")
        app.buttons["home-sheet-done-memory-summary"].tap()
        app.buttons["home-sheet-done-memory"].tap()
        app.buttons["home-sheet-done-chapter"].tap()
        app.buttons["home-sheet-done-chapters"].tap()

        open(app, "home-manage-tasks", ready: "home-task-active")
        expand(app, title: "Tasks")
        keep("08-tasks")
        open(app, "home-task-active", ready: "home-task-detail")
        expand(app, title: "Tasks")
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

    /// Drags the top sheet's title to the top so the sheet settles at its large detent.
    @MainActor private func expand(_ app: XCUIApplication, title: String) {
        let label = app.staticTexts.matching(identifier: title).allElementsBoundByIndex.last ?? app.staticTexts[title]
        guard label.exists else { return }
        label.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)))
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "frame.minY < 120"), object: label)], timeout: 3)
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
