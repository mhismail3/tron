import XCTest

final class TronTaskToolSheetUITests: XCTestCase {
    /// Visual review only: no Gateway mutation or behavioral acceptance suite.
    @MainActor func testCaptureTaskSheetReview() {
        continueAfterFailure = false
        for mode in ["light", "dark"] {
            for scenario in ["task-list", "task-status", "task-report", "task-steer", "task-fallback"] {
                let app = launch(scenario, mode: mode)
                capture(app, "\(scenario)-\(mode)")
                app.swipeUp()
                capture(app, "\(scenario)-\(mode)-lower")
                app.terminate()
            }
        }
        let app = launch("task-list", large: true)
        capture(app, "task-list-large-text")
        app.swipeUp()
        capture(app, "task-list-large-text-lower")
        app.terminate()
    }

    @MainActor private func launch(_ scenario: String, mode: String = "light", large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-tool-sheets-polish-fixture", "-polish-scenario", scenario,
                               "-polish-\(mode)", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.buttons["Technical details"].waitForExistence(timeout: 15), app.debugDescription)
        return app
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
