import XCTest

@MainActor
final class TronProjectLifecyclePreviewUITests: XCTestCase {
    func testProjectDrillInsReturnThroughTheirSubSheets() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        open(app, "Example")
        title(app, "Example")
        open(app, "project-preview-untrust")
        XCTAssertTrue(app.buttons["change-review-approve"].waitForExistence(timeout: 10))
        app.navigationBars.staticTexts["Review change"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        title(app, "Example")
        close(app)
        title(app, "Trusted Projects")
        open(app, "Add Project")
        title(app, "Add Project")
        open(app, "Create Project")
        title(app, "Create Project")
        close(app)
        title(app, "Add Project")
        open(app, "project-preview-existing")
        XCTAssertTrue(app.buttons["Use current folder"].waitForExistence(timeout: 10))
        app.buttons["Use current folder"].tap()
        title(app, "Add Project")
        close(app)
        title(app, "Trusted Projects")
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-expanded-review", "-settings-sheet-theme-review",
            "-project-lifecycle-preview", "list", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        return app
    }

    private func close(_ app: XCUIApplication) {
        guard let button = app.buttons.matching(NSPredicate(format: "label == 'Done'"))
            .allElementsBoundByIndex.last(where: { $0.isHittable }) else {
            XCTFail("No hittable Done button in the presented sheet")
            return
        }
        button.tap()
    }

    private func title(_ app: XCUIApplication, _ text: String) {
        XCTAssertTrue(app.navigationBars.staticTexts[text].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
    }

    private func open(_ app: XCUIApplication, _ identifier: String) {
        let button = app.buttons[identifier].firstMatch
        for _ in 0..<5 {
            if button.exists && button.isHittable { button.tap(); return }
            app.swipeUp()
        }
        XCTFail("Missing drill-in: \(identifier)\n\(app.debugDescription)")
    }
}
