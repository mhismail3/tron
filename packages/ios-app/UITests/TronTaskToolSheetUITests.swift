import XCTest

final class TronTaskToolSheetUITests: XCTestCase {

    @MainActor func testCatalogShowsTaskContentAndKeepsJSONInTechnicalDetails() {
        continueAfterFailure = false
        let app = launch("task-list")
        defer { app.terminate() }
        let task = app.descendants(matching: .any)["task-tool-row-photo-readiness"]
        XCTAssertTrue(task.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(task.label.contains("Keep Send disabled while photos prepare"))
        XCTAssertTrue(task.label.contains("Running"))
        XCTAssertTrue(task.label.contains("Attachment readiness now has one owner."))
        XCTAssertTrue(app.staticTexts["10 running · 495 finished"].exists)
        let stopped = app.descendants(matching: .any)["task-tool-row-older-layout-audit"]
        for _ in 0..<6 where !stopped.isHittable { app.swipeUp() }
        XCTAssertTrue(stopped.label.contains("older-layout-audit"))
        XCTAssertTrue(stopped.label.contains("Stopped"))
        XCTAssertTrue(app.descendants(matching: .any)["task-tool-row-tool-sheet-review"].label.contains("Needs attention"))
        XCTAssertTrue(app.staticTexts["More tasks are available."].exists)
        app.buttons["Technical details"].tap()
        let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Inspect Result JSON,")).firstMatch
        for _ in 0..<6 where !result.isHittable { app.swipeUp() }
        XCTAssertTrue(result.isHittable, app.debugDescription)
        result.tap()
        XCTAssertTrue(app.staticTexts["Result JSON"].waitForExistence(timeout: 5))
        let raw = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "photo-readiness")).firstMatch
        XCTAssertTrue(raw.waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-tool-sheets-polish-fixture", "-polish-scenario", scenario,
                               "-polish-light", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["Technical details"].waitForExistence(timeout: 15), app.debugDescription)
        return app
    }

}
