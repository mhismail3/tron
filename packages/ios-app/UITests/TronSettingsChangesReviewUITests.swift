import XCTest

/// Changes feed rows and its Filters sheet over the production managed-sheet
/// path (#1461): realistic audit rows, two Gateway-sized pages.
final class TronSettingsChangesReviewUITests: XCTestCase {
    @MainActor
    private func launch(dark: Bool = false, large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-changes-review",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if dark { app.launchArguments.append("-settings-renderer-dark") }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"] }
        app.launch()
        return app
    }

    /// Opens Changes from Global Settings' toolbar and expands the sheet to its large detent.
    @MainActor
    private func openChanges(_ app: XCUIApplication) {
        let link = app.buttons["Changes"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 15), app.debugDescription)
        link.tap()
        XCTAssertTrue(app.buttons["settings-change-review-0"].waitForExistence(timeout: 10), app.debugDescription)
        let heading = app.navigationBars.staticTexts["Changes"].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        heading.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)))
    }

    @MainActor
    private func keep(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    private func waitHittable(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isHittable { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return false
    }

    /// Loads the second page so the feed holds 100 rows behind the Filters sheet.
    @MainActor
    private func loadSecondPage(_ app: XCUIApplication) {
        let more = app.buttons["settings-changes-load-more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<40 where !more.isHittable { app.swipeUp(velocity: .fast) }
        more.tap()
        XCTAssertTrue(more.waitForNonExistence(timeout: 10), app.debugDescription)
        // The feed is lazy: the last row exists once it scrolls into view.
        let last = app.buttons["settings-change-review-99"]
        for _ in 0..<40 where !last.exists { app.swipeUp(velocity: .fast) }
        XCTAssertTrue(last.exists, app.debugDescription)
    }

    /// Rows (long values, every status, new and old, a known worker title and
    /// an unknown one), Filters and its Changed by picker, light/dark and large text.
    @MainActor
    func testChangesRowsAndFiltersPreviewLightDarkLargeText() {
        continueAfterFailure = false
        for (appearance, large) in [("light", false), ("dark", false), ("light", true), ("dark", true)] {
            let app = launch(dark: appearance == "dark", large: large)
            defer { app.terminate() }
            let suffix = "\(appearance)-\(large ? "ax-large" : "default")"
            openChanges(app)
            let worker = app.buttons["settings-change-review-0"]
            XCTAssertTrue(worker.label.contains("Restructure 0.4: compare ownership metadata"), worker.label)
            XCTAssertTrue(worker.label.contains("Home task task_01J9ZQ8K2M4R7XWV"), "VoiceOver keeps the audit actor: \(worker.label)")
            XCTAssertTrue(worker.label.hasSuffix("Since you last looked"), worker.label)
            keep(app, "1461-changes-rows-\(suffix)")
            app.buttons["settings-changes-filters"].tap()
            let actor = app.descendants(matching: .any)["settings-changes-actor"].buttons.firstMatch
            XCTAssertTrue(waitHittable(actor), app.debugDescription)
            keep(app, "1461-filters-\(suffix)")
            actor.tap()
            XCTAssertTrue(waitHittable(app.buttons["settings-option-Everyone"]), app.debugDescription)
            keep(app, "1461-filters-changed-by-\(suffix)")
        }
    }

    /// Filters' open, nested picker choice, expansion and close, measured as
    /// interactions (hitches and wall clock) with 100 rows behind the sheet.
    @MainActor
    func testChangesFiltersInteractionMeasurement() {
        continueAfterFailure = false
        let app = launch(); defer { app.terminate() }
        openChanges(app)
        loadSecondPage(app)
        let filters = app.buttons["settings-changes-filters"]
        let status = app.descendants(matching: .any)["settings-changes-status"].buttons.firstMatch
        let anyStatus = app.buttons["settings-option-Any status"]
        var timings: [String] = []
        var iteration = 0
        func timed(_ label: String, _ body: () -> Bool) {
            let start = Date()
            let passed = body()
            timings.append("\(iteration):\(label)=\(Int(Date().timeIntervalSince(start) * 1000))ms")
            print("1461-timing \(timings.last!)")
            if iteration == 0 || !passed { keep(app, "1461-measure-\(iteration)-\(label)") }
            XCTAssertTrue(passed, "\(label)\n\(app.debugDescription)")
        }
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        let window = app.windows.firstMatch
        measure(metrics: [XCTHitchMetric(application: app), XCTClockMetric()], options: options) {
            timed("open-filters") { filters.tap(); return waitHittable(status) }
            timed("open-status-picker") { status.tap(); return waitHittable(anyStatus) }
            timed("choose-status") { anyStatus.tap(); return anyStatus.waitForNonExistence(timeout: 5) && waitHittable(status) }
            // Coordinates, not queries: this drag and Done measure the sheet, not an accessibility snapshot.
            timed("expand-filters") {
                window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.53))
                    .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)))
                return true
            }
            keep(app, "1461-measure-\(iteration)-expanded")
            timed("close-filters") {
                window.coordinate(withNormalizedOffset: CGVector(dx: 0.905, dy: 0.125)).tap()
                return waitHittable(filters) && status.waitForNonExistence(timeout: 5)
            }
            iteration += 1
        }
        XCTAssertTrue(app.buttons["settings-change-review-99"].exists, "Unchanged filters keep the installed feed and its place")
        let report = XCTAttachment(string: timings.joined(separator: "\n"))
        report.name = "1461-filters-interaction-timings"
        report.lifetime = .keepAlways
        add(report)
    }
}
