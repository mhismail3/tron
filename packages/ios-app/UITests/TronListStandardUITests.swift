import XCTest

/// The shared list standard (#1691) across the eight Manage Home and Manage
/// Session list sheets, driven through their real fixtures.
final class TronListStandardUITests: XCTestCase {
    @MainActor func testCaptureHomeSheetsLight() { captureHome(dark: false) }
    @MainActor func testCaptureHomeSheetsDark() { captureHome(dark: true) }
    @MainActor func testCaptureSessionSheetsLight() { captureSession(dark: false) }
    @MainActor func testCaptureSessionSheetsDark() { captureSession(dark: true) }
    @MainActor func testCaptureInstructionsAndSubagents() {
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            let app = XCUIApplication()
            app.launchArguments = ["-tron-agent-instructions-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + (dark ? ["-home-dark"] : [])
            app.launch()
            XCTAssertTrue(element(app, "agent-instructions-section-preamble").waitForExistence(timeout: 10), app.debugDescription)
            expandSheet(app, title: "Instructions")
            shot("instructions-\(mode)")
            app.terminate()
            app.launchArguments = ["-tron-subagent-parity-fixture", "-history-grouping", dark ? "-dark" : "-light"]
            app.launch()
            let open = app.buttons["Subagent History"]
            XCTAssertTrue(open.waitForExistence(timeout: 10), app.debugDescription)
            open.tap()
            XCTAssertTrue(app.buttons["subagent-row-worker"].waitForExistence(timeout: 5), app.debugDescription)
            expandSheet(app, title: "Subagent History")
            shot("subagent-history-\(mode)")
            app.terminate()
        }
    }

    @MainActor private func captureHome(dark: Bool) {
        continueAfterFailure = false
        let mode = dark ? "dark" : "light"
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-paging"] + (dark ? ["-home-dark"] : [])
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        let ring = app.buttons["session-context-button"]
        XCTAssertTrue(waitFor(ring, "enabled == true"))
        ring.tap()
        XCTAssertTrue(element(app, "home-manage-state").waitForExistence(timeout: 10), app.debugDescription)
        expandSheet(app, title: "Manage Home")
        for (row, title, done, name) in [("home-manage-profile", "Profile", "home-sheet-done-profile", "profile"),
                                         ("home-manage-chapters", "Chapters", "home-sheet-done-chapters", "chapters")] {
            let open = element(app, row)
            for _ in 0..<6 where !open.isHittable { app.swipeUp() }
            open.tap()
            expandSheet(app, title: title)
            Thread.sleep(forTimeInterval: 1)
            shot("\(name)-\(mode)")
            app.buttons[done].tap()
            Thread.sleep(forTimeInterval: 0.8)
        }
        let memory = element(app, "home-manage-memory-browser")
        for _ in 0..<6 where !memory.isHittable { app.swipeUp() }
        memory.tap()
        expandSheet(app, title: "Memory")
        Thread.sleep(forTimeInterval: 1)
        shot("memory-top-\(mode)")
        for _ in 0..<2 { app.swipeUp() }
        Thread.sleep(forTimeInterval: 1)
        shot("memory-scrolled-\(mode)")
        app.buttons["home-sheet-done-memory"].tap()
        Thread.sleep(forTimeInterval: 0.8)
        let tasks = element(app, "home-manage-tasks")
        for _ in 0..<6 where !tasks.isHittable { app.swipeUp() }
        tasks.tap()
        expandSheet(app, title: "Tasks")
        Thread.sleep(forTimeInterval: 1)
        shot("tasks-top-\(mode)")
        for _ in 0..<4 { app.swipeUp() }
        // The fixture refuses the first older page once: the feed keeps its rows and offers Retry.
        if element(app, "feed-retry").waitForExistence(timeout: 5) {
            shot("tasks-error-\(mode)")
            element(app, "feed-retry").tap()
        }
        for _ in 0..<8 { app.swipeUp() }
        Thread.sleep(forTimeInterval: 1)
        shot("tasks-end-\(mode)")
    }

    @MainActor private func captureSession(dark: Bool) {
        continueAfterFailure = false
        let mode = dark ? "dark" : "light"
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-configuration-fixture", "-manage-session-review", "-history-large",
                               "-fixture-appearance", mode]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 10))
        app.buttons["Stop session"].tap()
        let history = app.buttons["Session History"]
        for _ in 0..<12 where !history.isHittable { app.swipeUp() }
        history.tap()
        XCTAssertTrue(element(app, "history-row-h-6732").waitForExistence(timeout: 10), app.debugDescription)
        expandSheet(app, title: "Session History")
        Thread.sleep(forTimeInterval: 1)
        shot("history-top-\(mode)")
        for _ in 0..<5 { app.swipeUp(velocity: .fast) }
        Thread.sleep(forTimeInterval: 0.3)
        shot("history-scrolled-\(mode)")
        Thread.sleep(forTimeInterval: 1.5)
        let chip = element(app, "feed-position-chip")
        XCTAssertTrue(chip.waitForExistence(timeout: 5), app.debugDescription)
        chip.tap()
        Thread.sleep(forTimeInterval: 1)
        let row = element(app, "history-row-h-6731")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.press(forDuration: 1.0)
        Thread.sleep(forTimeInterval: 1)
        shot("history-menu-\(mode)")
        XCTAssertTrue(app.buttons["Fork New Session"].exists, app.debugDescription)
        // Dismiss the menu without choosing an action.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        Thread.sleep(forTimeInterval: 1)
        row.tap()
        XCTAssertTrue(element(app, "history-entry-actions").waitForExistence(timeout: 8), app.debugDescription)
        expandSheet(app, title: "History Entry")
        Thread.sleep(forTimeInterval: 1)
        shot("history-detail-\(mode)")
        app.navigationBars.containing(.staticText, identifier: "History Entry").buttons["Done"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1)
        app.navigationBars.containing(.staticText, identifier: "Session History").buttons["Done"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1)
        let resources = app.buttons.matching(NSPredicate(format: "label IN {'Resources', 'Project Resources'}")).firstMatch
        for _ in 0..<8 where !resources.isHittable { app.swipeUp() }
        resources.tap()
        XCTAssertTrue(app.buttons["project-resource-skills-0"].waitForExistence(timeout: 10), app.debugDescription)
        expandSheet(app, title: "Resources")
        Thread.sleep(forTimeInterval: 1)
        shot("resources-\(mode)")
        app.swipeUp()
        Thread.sleep(forTimeInterval: 1)
        shot("resources-bottom-\(mode)")
    }

    /// Session History over 6,733 entries: time to the first rows, time and swipes
    /// to auto-load 1,000 entries, then scroll hitches and memory with them loaded.
    @MainActor func testLargeHistoryScrollPerformance() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-configuration-fixture", "-history-large", "-fixture-appearance", "light"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 10))
        app.buttons["Stop session"].tap()
        let history = app.buttons["Session History"]
        for _ in 0..<12 where !history.isHittable { app.swipeUp() }
        let opened = Date()
        history.tap()
        XCTAssertTrue(app.buttons["history-row-h-6732"].waitForExistence(timeout: 10), app.debugDescription)
        let firstRows = Date().timeIntervalSince(opened)
        expandSheet(app, title: "Session History")
        let target = app.buttons["history-row-h-5733"]
        let started = Date()
        var swipes = 0
        while !target.exists && swipes < 400 { app.swipeUp(velocity: .fast); swipes += 1 }
        let loaded = Date().timeIntervalSince(started)
        XCTAssertTrue(target.exists, "1,000 entries auto-load by scrolling alone")
        let report = String(format: "list-standard-perf firstRows=%.2fs load1000=%.1fs swipes=%d perSwipe=%.2fs", firstRows, loaded, swipes, loaded / Double(max(swipes, 1)))
        print(report)
        let attachment = XCTAttachment(string: report)
        attachment.name = "large-history-perf"
        attachment.lifetime = .keepAlways
        add(attachment)
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric, XCTMemoryMetric(application: app)], options: options) {
            app.swipeUp(velocity: .fast)
            app.swipeDown(velocity: .fast)
        }
    }

    // MARK: Helpers

    @MainActor private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func waitFor(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 10) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)], timeout: timeout) == .completed
    }

    /// Brings a sheet to its large detent by dragging its title toward the top.
    @MainActor private func expandSheet(_ app: XCUIApplication, title text: String) {
        let title = app.navigationBars.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 8), app.debugDescription)
        var last = title.frame.minY
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.3)
            let now = title.frame.minY
            if abs(now - last) < 0.5 { break }
            last = now
        }
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        for _ in 0..<4 where title.frame.minY > 120 {
            origin.withOffset(CGVector(dx: 60, dy: title.frame.midY))
                .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: 60, dy: 20)))
            Thread.sleep(forTimeInterval: 0.6)
        }
    }
}
