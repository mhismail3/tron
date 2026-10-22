import XCTest

/// Manage Session, Manage Home and the sheets they open share one emerald sheet
/// theme; each sub-sheet is titled by the row that opens it; Instructions rows
/// keep their summary on the title's line (#1680). The Capture journeys keep the
/// light/dark review images.
final class TronManageSheetsThemeUITests: XCTestCase {
    @MainActor func testCaptureManageSessionSheets() {
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            let app = launchManageSession(dark: dark); defer { app.terminate() }
            shot("manage-session-top-\(mode)")
            open(app, row: "Workspace")
            shot("workspace-\(mode)")
            closeTop(app)
            open(app, row: "Resources")
            shot("resources-\(mode)")
            closeTop(app)
            open(app, row: "Instructions")
            shot("instructions-from-manage-session-\(mode)")
            closeTop(app)
            app.terminate()
        }
    }

    @MainActor func testCaptureManageHomeSheets() {
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            let app = launchManageHome(dark: dark); defer { app.terminate() }
            shot("manage-home-top-\(mode)")
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.6)
            shot("manage-home-bottom-\(mode)")
            app.swipeDown()
            Thread.sleep(forTimeInterval: 0.6)
            for (row, done) in [("home-manage-memory-browser", "home-sheet-done-memory"),
                                ("home-manage-profile", "home-sheet-done-profile")] {
                element(app, row).tap()
                expand(app, done: done)
                Thread.sleep(forTimeInterval: 0.8)
                shot("\(row.replacingOccurrences(of: "home-manage-", with: "home-"))-\(mode)")
                app.buttons[done].tap()
                Thread.sleep(forTimeInterval: 0.6)
            }
        }
    }

    @MainActor func testCaptureInstructions() {
        for (name, arguments) in [("light", [String]()), ("dark", ["-home-dark"]),
                                  ("xxxl-light", ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])] {
            let app = launchInstructions(arguments); defer { app.terminate() }
            expand(app, title: app.navigationBars.staticTexts.firstMatch.label)
            Thread.sleep(forTimeInterval: 0.6)
            shot("instructions-\(name)")
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.6)
            shot("instructions-\(name)-bottom")
            if name.hasPrefix("xxxl") {
                for page in 2...4 {
                    app.swipeUp()
                    Thread.sleep(forTimeInterval: 0.6)
                    shot("instructions-\(name)-bottom\(page)")
                }
            }
            app.buttons["agent-instructions-full-prompt"].firstMatch.tap()
            Thread.sleep(forTimeInterval: 1.2)
            shot("instructions-full-prompt-\(name)")
            closeTop(app)
            Thread.sleep(forTimeInterval: 0.6)
            let tools = app.buttons["agent-instructions-section-tools"]
            for _ in 0..<4 where !tools.isHittable { app.swipeDown() }
            tools.tap()
            Thread.sleep(forTimeInterval: 1.2)
            shot("instructions-tools-section-\(name)")
            app.terminate()
        }
    }

    // MARK: Journeys

    @MainActor private func launchManageSession(dark: Bool) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-configuration-fixture", "-settings-scope-review", "-manage-session-review",
                               "-fixture-appearance", dark ? "dark" : "light"]
        app.launch()
        XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 10))
        app.buttons["Stop session"].tap()
        XCTAssertTrue(element(app, "session-usage-summary").waitForExistence(timeout: 10), app.debugDescription)
        expand(app, title: "Manage Session")
        return app
    }

    @MainActor private func launchManageHome(dark: Bool) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"] + (dark ? ["-home-dark"] : [])
        app.launch()
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 15))
        app.buttons["home-pinned-row"].tap()
        let ring = app.buttons["session-context-button"]
        XCTAssertTrue(waitFor(ring, "enabled == true"))
        ring.tap()
        XCTAssertTrue(element(app, "home-manage-state").waitForExistence(timeout: 8), app.debugDescription)
        expand(app, done: "home-sheet-done-manage")
        Thread.sleep(forTimeInterval: 0.6)
        return app
    }

    @MainActor private func launchInstructions(_ arguments: [String]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-agent-instructions-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["agent-instructions-section-preamble"].waitForExistence(timeout: 10), app.debugDescription)
        return app
    }

    /// Taps a Manage Session row by its label and waits for its sheet to settle large.
    @MainActor private func open(_ app: XCUIApplication, row label: String) {
        let row = app.buttons[label].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), app.debugDescription)
        for _ in 0..<6 where !row.isHittable { app.swipeUp() }
        row.tap()
        Thread.sleep(forTimeInterval: 1.0)
        let title = app.navigationBars.staticTexts.allElementsBoundByIndex.last?.label ?? label
        expand(app, title: title)
        Thread.sleep(forTimeInterval: 1.0)
    }

    // MARK: Helpers

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Brings the sheet titled `text` to its large detent once it stops presenting.
    @MainActor private func expand(_ app: XCUIApplication, title text: String) {
        let title = app.navigationBars.staticTexts.matching(NSPredicate(format: "label == %@", text)).allElementsBoundByIndex.last
            ?? app.staticTexts[text].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 8), app.debugDescription)
        var last = title.frame.minY
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.3)
            if abs(title.frame.minY - last) < 0.5 { break }
            last = title.frame.minY
        }
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        for _ in 0..<3 where title.frame.minY > 120 {
            origin.withOffset(CGVector(dx: 60, dy: title.frame.midY))
                .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: 60, dy: 20)))
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "frame.minY < 120"), object: title)], timeout: 2)
        }
    }

    @MainActor private func expand(_ app: XCUIApplication, done id: String) {
        let done = app.buttons[id].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 8), id)
        guard done.frame.minY > 120 else { return }
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: 60, dy: done.frame.midY))
            .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: 60, dy: 20)))
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "frame.minY < 120"), object: done)], timeout: 3)
    }

    @MainActor private func closeTop(_ app: XCUIApplication) {
        let done = app.buttons.matching(NSPredicate(format: "label == 'Done'")).allElementsBoundByIndex.last(where: \.isHittable)
        XCTAssertNotNil(done, app.debugDescription)
        done?.tap()
        Thread.sleep(forTimeInterval: 0.8)
    }

    private func waitFor(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 10) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)], timeout: timeout) == .completed
    }

    @MainActor private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
