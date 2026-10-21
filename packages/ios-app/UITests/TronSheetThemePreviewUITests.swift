import XCTest

/// Navigation-only simulator captures for maintainer review, not regression acceptance.
@MainActor
final class TronSheetThemePreviewUITests: XCTestCase {
    func testSettingsSheetPreviewLightDark() {
        continueAfterFailure = false
        for mode in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-nested", "-settings-expanded-review", "-settings-sheet-theme-review"]
            if mode == "dark" { app.launchArguments.append("-settings-renderer-dark") }
            app.launch()
            defer { app.terminate() }
            XCTAssertTrue(app.buttons["Open Settings"].waitForExistence(timeout: 15))
            app.buttons["Open Settings"].tap()
            expand(app, title: "Global Settings")
            open(app, "settings-section-advanced-open")
            expand(app, title: "More Settings")
            capture(app, "more-top-\(mode)")
            app.swipeUp(); app.swipeUp()
            capture(app, "more-bottom-\(mode)")
            close(app)
            open(app, "settings-section-model-open")
            expand(app, title: "Models")
            capture(app, "models-top-\(mode)")
            app.swipeUp(); app.swipeUp()
            capture(app, "models-bottom-\(mode)")
            close(app)
            open(app, "settings-link-Connections")
            expand(app, title: "Connections")
            capture(app, "connections-\(mode)")
            open(app, "Details for Fixture")
            expand(app, title: "Fixture")
            capture(app, "server-top-\(mode)")
            app.swipeUp(); app.swipeUp()
            capture(app, "server-bottom-\(mode)")
            open(app, "Configure source repository")
            XCTAssertTrue(app.buttons["Use current folder"].waitForExistence(timeout: 10))
            capture(app, "workspace-server-\(mode)")
            app.navigationBars.staticTexts["/fixture/projects"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
            close(app); close(app)
            open(app, "settings-link-Trusted Projects")
            expand(app, title: "Trusted Projects")
            app.buttons["Add Project"].tap()
            XCTAssertTrue(app.buttons["Use current folder"].waitForExistence(timeout: 10))
            capture(app, "workspace-trusted-\(mode)")
            app.terminate()
        }
    }

    private func open(_ app: XCUIApplication, _ id: String) {
        let button = app.buttons[id].firstMatch
        for _ in 0..<7 {
            if button.exists && button.isHittable { button.tap(); return }
            app.swipeUp()
        }
        for _ in 0..<7 {
            if button.exists && button.isHittable { button.tap(); return }
            app.swipeDown()
        }
        XCTFail("Cannot open \(id): \(app.debugDescription)")
    }

    private func expand(_ app: XCUIApplication, title: String) {
        let title = app.navigationBars.staticTexts[title].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), app.debugDescription)
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)))
    }

    private func close(_ app: XCUIApplication) {
        app.buttons.matching(NSPredicate(format: "label == 'Done'")).allElementsBoundByIndex.last { $0.isHittable }?.tap()
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "presentation settles")], timeout: 1)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "1611-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
