import XCTest

/// Manage Home and every sub-sheet, walked end to end on the hosted Home fixture
/// (#911). The journey proves the sheet structure, the memory hierarchy Home sees,
/// the removed task controls, and that returning to a loaded sheet reads nothing
/// again. Each step keeps a large-detent screenshot, and the open timings and read
/// counts are kept as a JSON attachment (`home-sheet-measurements`).
final class TronHomeSheetsUITests: XCTestCase {
    private var timings: [String: Double] = [:]

    @MainActor
    func testHomeSheetsJourney() {
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
        open(app, ring, ready: "home-manage-state", name: "manage")
        keep("00-manage-medium")
        expand(app, done: "home-sheet-done-manage")
        keep("01-manage")

        // Manage Home's top card is Home's context: the state pill and the last
        // activation, a section-segmented bar, then the legend above the metrics.
        // There is no separate Home Context sheet.
        XCTAssertFalse(element(app, "home-manage-context").exists, "Home Context is part of Manage Home")
        XCTAssertTrue(element(app, "context-segmented-bar").exists)
        XCTAssertTrue(element(app, "context-segment-memory").label.contains("260 summaries"))
        XCTAssertTrue(element(app, "home-context-activation").label.hasPrefix("Your message"))
        let cacheHit = element(app, "home-context-breakdown").descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Cache Hit'")).firstMatch
        XCTAssertTrue(cacheHit.exists)
        XCTAssertLessThanOrEqual(element(app, "context-segment-free").frame.maxY, cacheHit.frame.minY, "The legend sits above the metrics")

        // Home Settings is its own container below the rows container.
        app.swipeUp()
        let settings = element(app, "home-manage-settings"), permissions = element(app, "home-manage-permissions")
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(settings.frame.minY, permissions.frame.maxY + 8, "Home Settings sits in a separate container")
        keep("01b-manage-bottom")
        app.swipeDown()

        // Memory: the recent messages and the summaries Home sees, without raw kind prefixes.
        open(app, element(app, "home-manage-memory-browser"), ready: "home-memory-row-39", name: "memory")
        expand(app, done: "home-sheet-done-memory")
        XCTAssertTrue(element(app, "home-memory-recent").exists)
        XCTAssertTrue(element(app, "home-memory-summaries").exists)
        XCTAssertTrue(element(app, "home-memory-summary-32-2").exists)
        XCTAssertTrue(element(app, "home-memory-row-39").label.hasPrefix("Result, Task result:"))
        let prefixed = NSPredicate(format: "label BEGINSWITH 'user:' OR label BEGINSWITH 'talk:' OR label BEGINSWITH 'echo:' OR label BEGINSWITH 'event:'")
        XCTAssertEqual(app.staticTexts.matching(prefixed).count, 0, "Memory rows never show raw kind prefixes")
        let markdown = element(app, "home-memory-row-37")
        XCTAssertTrue(markdown.label.contains("garden review"), markdown.label)
        XCTAssertFalse(markdown.label.contains("**") || markdown.label.contains("`"), "Memory previews render markdown: \(markdown.label)")
        keep("03-memory")
        open(app, element(app, "home-memory-row-39"), ready: "home-memory-detail", name: "memory-item")
        XCTAssertFalse(element(app, "home-memory-remembered").exists, "A summary equal to the message is not repeated")
        keep("04-memory-item")
        app.buttons["home-sheet-done-memory-item"].tap()
        app.buttons["home-sheet-done-memory"].tap()

        // Chapters: a chapter opens from the loaded row, and returning reads nothing again.
        open(app, element(app, "home-manage-chapters"), ready: "home-chapter-1", name: "chapters")
        expand(app, done: "home-sheet-done-chapters")
        keep("05-chapters")
        let chaptersLoaded = reads(app)
        open(app, element(app, "home-chapter-2"), ready: "home-chapter-detail", name: "chapter")
        XCTAssertEqual(reads(app), chaptersLoaded, "A chapter opens from the row already loaded")
        XCTAssertFalse(element(app, "home-chapter-open-transcript").exists, "The current chapter is this chat and has no transcript row")
        app.buttons["home-sheet-done-chapter"].tap()
        XCTAssertTrue(element(app, "home-chapter-1").exists, "Chapters keeps its rows while a child closes")
        XCTAssertFalse(element(app, "home-sheet-loading").exists, "Returning to Chapters shows no loading state")
        assertNoReads(app, since: chaptersLoaded, "Returning to Chapters re-reads nothing")
        open(app, element(app, "home-chapter-1"), ready: "home-chapter-detail", name: "chapter-sealed")
        expand(app, done: "home-sheet-done-chapter")
        XCTAssertTrue(element(app, "home-chapter-header").exists)
        XCTAssertTrue(element(app, "home-chapter-size").label.contains("hard limit"))
        XCTAssertTrue(element(app, "home-chapter-topics").exists)
        XCTAssertTrue(element(app, "home-chapter-open-transcript").exists)
        keep("06-chapter-sealed")

        // A previous chapter's memory: its summary lines, opened down to one message.
        open(app, element(app, "home-chapter-browse-memory"), ready: "home-memory-summary-28-4", name: "chapter-memory")
        expand(app, done: "home-sheet-done-memory")
        XCTAssertFalse(element(app, "home-memory-row-39").exists, "Chapter 1's memory holds only its own lines")
        keep("07-chapter-memory")
        open(app, element(app, "home-memory-summary-28-4"), ready: "home-memory-summary-detail", name: "memory-summary")
        expand(app, done: "home-sheet-done-memory-summary")
        XCTAssertTrue(element(app, "home-memory-summary-28-2").exists)
        XCTAssertTrue(element(app, "home-memory-summary-30-2").exists)
        keep("07b-memory-summary")
        open(app, element(app, "home-memory-summary-30-2").firstMatch, ready: "home-memory-row-31", name: "memory-half")
        open(app, element(app, "home-memory-row-31"), ready: "home-memory-detail", name: "memory-half-item")
        let memoryOpened = reads(app)
        app.buttons["home-sheet-done-memory-item"].tap()
        assertNoReads(app, since: memoryOpened, "Returning to a summary re-reads nothing")
        for _ in 0..<2 { app.buttons["home-sheet-done-memory-summary"].firstMatch.tap() }
        app.buttons["home-sheet-done-memory"].tap()
        app.buttons["home-sheet-done-chapter"].tap()
        XCTAssertTrue(element(app, "home-chapter-1").waitForExistence(timeout: 3))
        assertNoReads(app, since: memoryOpened, "Closing the memory and chapter sheets re-reads nothing")
        let finalReads = reads(app)
        app.buttons["home-sheet-done-chapters"].tap()

        // Tasks: shared rows; the detail has no Stop, Steer or Reload, and opens the worker session.
        open(app, element(app, "home-manage-tasks"), ready: "home-task-active", name: "tasks")
        expand(app, done: "home-sheet-done-tasks")
        keep("08-tasks")
        open(app, element(app, "home-task-active"), ready: "home-task-detail", name: "task")
        expand(app, done: "home-sheet-done-task")
        for removed in ["home-task-stop", "home-task-steer", "home-task-steer-send", "home-task-reload", "home-tasks-reload", "home-task-open-worker"] {
            XCTAssertFalse(element(app, removed).exists, removed)
        }
        XCTAssertTrue(element(app, "home-task-header").exists)
        XCTAssertTrue(element(app, "home-task-spend").label.contains("12 in"))
        keep("09-task-detail")
        app.buttons["home-task-open-session"].tap()
        XCTAssertTrue(waitFor(app.staticTexts["fixture.home-opened-session"], "label CONTAINS 'opened-session:worker-session'"))
        XCTAssertFalse(app.buttons["Manage Home"].exists, "The worker chat is an ordinary session and must not claim Home")

        let report = XCTAttachment(string: String(data: try! JSONSerialization.data(withJSONObject: [
            "openMs": timings, "homeReadsAfterChapterJourney": finalReads,
        ], options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
        report.name = "home-sheet-measurements"; report.lifetime = .keepAlways
        add(report)
    }

    // MARK: - Helpers

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Taps a row and waits for the sheet it opens, recording the tap-to-content time.
    @MainActor private func open(_ app: XCUIApplication, _ row: XCUIElement, ready: String, name: String) {
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(name)\n\(app.debugDescription)")
        let started = Date()
        row.tap()
        XCTAssertTrue(element(app, ready).waitForExistence(timeout: 8), "\(ready)\n\(app.debugDescription)")
        timings[name] = (Date().timeIntervalSince(started) * 1000).rounded()
    }

    /// The fixture's Home read counts; the fixture publishes each before answering it.
    @MainActor private func reads(_ app: XCUIApplication) -> String {
        app.staticTexts["fixture.home-read-counts"].label
    }

    /// Fails if any Home read is sent within the window: a sheet uncovered by its
    /// child must keep its page rather than re-read it.
    @MainActor private func assertNoReads(_ app: XCUIApplication, since baseline: String, _ message: String) {
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", baseline),
                                                object: app.staticTexts["fixture.home-read-counts"])
        changed.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 1.5), .completed, "\(message): \(reads(app))")
    }

    /// Drags the top sheet by its navigation bar (beside the title, never over content)
    /// so it settles at its large detent; its Done button names the sheet.
    @MainActor private func expand(_ app: XCUIApplication, done id: String) {
        let done = app.buttons[id].firstMatch
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
