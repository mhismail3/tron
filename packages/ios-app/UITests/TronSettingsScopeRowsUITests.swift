import XCTest

/// Overridden rows in Home, Session and Project settings at their reported
/// lengths (#1651), through the hosted Home and Manage Session fixtures.
final class TronSettingsScopeRowsUITests: XCTestCase {
    @MainActor func testHomeModelsLight() { homeModels(dark: false) }
    @MainActor func testHomeModelsDark() { homeModels(dark: true) }
    @MainActor func testSessionAndProjectLight() { sessionAndProject(dark: false) }
    @MainActor func testSessionAndProjectDark() { sessionAndProject(dark: true) }

    @MainActor private func homeModels(dark: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-settings-scope-review"] + (dark ? ["-home-dark"] : [])
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 15))
        app.buttons["home-pinned-row"].tap()
        let ring = app.buttons["session-context-button"]
        XCTAssertTrue(ring.waitForExistence(timeout: 15))
        XCTAssertTrue(waitFor(ring, "enabled == true"))
        ring.tap()
        let row = element(app, "home-manage-settings")
        XCTAssertTrue(row.waitForExistence(timeout: 8), app.debugDescription)
        for _ in 0..<8 where !row.isHittable { app.swipeUp() }
        row.tap()
        expandSheet(app, title: "Home Settings")
        let models = app.buttons["settings-section-model-open"]
        XCTAssertTrue(models.waitForExistence(timeout: 8), app.debugDescription)
        shot("1651-home-settings-\(dark ? "dark" : "light")")
        models.tap()
        expandSheet(app, title: "Models")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'settings-row-model.ref'"))
            .firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        shot("1651-home-models-\(dark ? "dark" : "light")")
        app.swipeUp()
        shot("1651-home-models-\(dark ? "dark" : "light")-bottom")
    }

    @MainActor private func sessionAndProject(dark: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-configuration-fixture", "-settings-scope-review",
                               "-fixture-appearance", dark ? "dark" : "light"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 10))
        app.buttons["Stop session"].tap()
        let link = app.buttons["chat-settings-link"]
        for _ in 0..<12 where !link.isHittable { app.swipeUp() }
        link.tap()
        expandSheet(app, title: "Session Settings")
        let toolsLink = app.buttons["settings-section-tools-open"]
        XCTAssertTrue(toolsLink.waitForExistence(timeout: 8), app.debugDescription)
        shot("1651-session-settings-\(dark ? "dark" : "light")")
        toolsLink.tap()
        expandSheet(app, title: "Tools")
        XCTAssertTrue(element(app, "settings-row-tools.active").waitForExistence(timeout: 8), app.debugDescription)
        shot("1651-session-tools-\(dark ? "dark" : "light")")
        app.navigationBars.containing(.staticText, identifier: "Tools").buttons["Done"].firstMatch.tap()
        let modelsLink = app.buttons["settings-section-model-open"]
        XCTAssertTrue(modelsLink.waitForExistence(timeout: 5), app.debugDescription)
        _ = waitFor(modelsLink, "hittable == true", timeout: 5)
        modelsLink.tap()
        expandSheet(app, title: "Models")
        shot("1651-session-models-\(dark ? "dark" : "light")")
        app.navigationBars.containing(.staticText, identifier: "Models").buttons["Done"].firstMatch.tap()
        _ = waitFor(modelsLink, "hittable == true", timeout: 5)
        app.navigationBars.containing(.staticText, identifier: "Session Settings").buttons["Done"].firstMatch.tap()
        let project = app.buttons["project-settings-link"]
        XCTAssertTrue(project.waitForExistence(timeout: 5), app.debugDescription)
        // The pop back to Manage Session settles before its rows take taps.
        _ = waitFor(project, "hittable == true", timeout: 5)
        for _ in 0..<4 where !project.isHittable { app.swipeUp() }
        for _ in 0..<8 where !project.isHittable { app.swipeDown() }
        project.tap()
        expandSheet(app, title: "Project Settings")
        _ = app.staticTexts["No repository overrides"].waitForExistence(timeout: 8)
        shot("1651-project-settings-\(dark ? "dark" : "light")")
    }

    /// Brings a settings sheet to its large detent once it stops presenting.
    @MainActor private func expandSheet(_ app: XCUIApplication, title text: String) {
        let title = app.navigationBars.staticTexts[text].firstMatch
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
