import XCTest

/// Manage Session, its folded Project section and the Resources sheet (#1655),
/// through the hosted Manage Session fixture with reported usage, a Git
/// workspace and resources of every kind and source.
final class TronManageSessionReviewUITests: XCTestCase {
    @MainActor func testCaptureManageSessionLight() { captureManageSession(dark: false) }
    @MainActor func testCaptureManageSessionDark() { captureManageSession(dark: true) }
    @MainActor func testCaptureResourcesLight() { captureResources(dark: false) }
    @MainActor func testCaptureResourcesDark() { captureResources(dark: true) }

    // MARK: Journeys

    @MainActor private func launch(dark: Bool) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-configuration-fixture", "-settings-scope-review", "-manage-session-review",
                               "-fixture-appearance", dark ? "dark" : "light"]
        app.launch()
        XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 10))
        app.buttons["Stop session"].tap()
        XCTAssertTrue(element(app, "session-usage-summary").waitForExistence(timeout: 10), app.debugDescription)
        expandSheet(app, title: "Manage Session")
        return app
    }

    @MainActor private func captureManageSession(dark: Bool) {
        let app = launch(dark: dark); defer { app.terminate() }
        let mode = dark ? "dark" : "light"
        shot("manage-session-top-\(mode)")
        for _ in 0..<3 { app.swipeUp() }
        Thread.sleep(forTimeInterval: 0.6)
        shot("manage-session-bottom-\(mode)")
        let link = app.buttons["chat-settings-link"]
        for _ in 0..<12 where !link.isHittable { app.swipeDown() }
        link.tap()
        expandSheet(app, title: "Session Settings")
        XCTAssertTrue(app.buttons["settings-section-model-open"].waitForExistence(timeout: 8), app.debugDescription)
        shot("session-settings-top-\(mode)")
        for _ in 0..<3 { app.swipeUp() }
        Thread.sleep(forTimeInterval: 0.6)
        shot("session-settings-bottom-\(mode)")
        let models = app.buttons["settings-section-model-open"]
        for _ in 0..<6 where !models.isHittable { app.swipeDown() }
        models.tap()
        expandSheet(app, title: "Models")
        shot("session-models-\(mode)")
        app.navigationBars.containing(.staticText, identifier: "Models").buttons["Done"].firstMatch.tap()
        _ = waitFor(models, "hittable == true", timeout: 5)
        app.navigationBars.containing(.staticText, identifier: "Session Settings").buttons["Done"].firstMatch.tap()
        // The base build's separate Project Settings sheet, when it still exists.
        let project = app.buttons["project-settings-link"]
        if project.waitForExistence(timeout: 3) {
            _ = waitFor(project, "hittable == true", timeout: 5)
            project.tap()
            expandSheet(app, title: "Project Settings")
            _ = app.staticTexts["No repository overrides"].waitForExistence(timeout: 8)
            shot("project-settings-\(mode)")
        }
    }

    @MainActor private func captureResources(dark: Bool) {
        let mode = dark ? "dark" : "light"
        for (kind, name) in [("commands", "command"), ("subagents", "subagent")] {
            let app = launch(dark: dark)
            openResources(app)
            if kind == "commands" {
                shot("resources-top-\(mode)")
                app.swipeUp()
                Thread.sleep(forTimeInterval: 0.6)
                shot("resources-bottom-\(mode)")
            }
            let row = app.buttons["project-resource-\(kind)-0"]
            for _ in 0..<8 where !row.isHittable { app.swipeUp() }
            row.tap()
            Thread.sleep(forTimeInterval: 1.5)
            shot("\(name)-detail-\(mode)")
            let viewAll = app.buttons["project-resource-view-all"]
            if viewAll.waitForExistence(timeout: 3) {
                for _ in 0..<4 where !viewAll.isHittable { app.swipeUp() }
                viewAll.tap()
                Thread.sleep(forTimeInterval: 1.5)
                shot("\(name)-reader-\(mode)")
                for _ in 0..<6 { app.swipeUp() }
                Thread.sleep(forTimeInterval: 0.6)
                shot("\(name)-reader-end-\(mode)")
            }
            app.terminate()
        }
    }

    @MainActor private func openResources(_ app: XCUIApplication) {
        let row = app.buttons.matching(NSPredicate(format: "label IN {'Resources', 'Project Resources'}")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), app.debugDescription)
        for _ in 0..<8 where !row.isHittable { app.swipeUp() }
        row.tap()
        XCTAssertTrue(app.buttons["project-resource-skills-0"].waitForExistence(timeout: 10), app.debugDescription)
        expandSheet(app, title: row.label)
    }

    // MARK: Helpers

    /// Brings a sheet to its large detent once it stops presenting.
    @MainActor private func expandSheet(_ app: XCUIApplication, title text: String) {
        let title = app.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch
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

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
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
