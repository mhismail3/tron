import XCTest

/// Navigation and screenshots only, for visual approval before behavioral tests.
@MainActor final class TronThemeIconPreviewUITests: XCTestCase {
    func testBuiltInThemeIconPreviews() {
        continueAfterFailure = false
        for theme in ["emerald", "burgundy", "oliveGold"] {
            for mode in ["light", "dark"] {
                let dashboard = XCUIApplication()
                dashboard.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready",
                    "-dashboard-view-home", "-themeColor", theme] + (mode == "dark" ? ["-home-dark"] : [])
                dashboard.launch()
                XCTAssertTrue(dashboard.buttons["home-pinned-row"].waitForExistence(timeout: 15))
                capture("\(theme)-\(mode)-dashboard")
                dashboard.terminate()

                let settings = XCUIApplication()
                settings.launchArguments = ["-tron-settings-renderer-fixture", "-settings-nested",
                    "-settings-expanded-review", "-themeColor", theme]
                    + (mode == "dark" ? ["-settings-renderer-dark"] : [])
                settings.launch()
                XCTAssertTrue(settings.buttons["Open Settings"].waitForExistence(timeout: 15))
                settings.buttons["Open Settings"].tap()
                expand(settings, "Global Settings")
                settings.buttons["Appearance"].tap()
                expand(settings, "Appearance")
                XCTAssertTrue(settings.buttons["theme-color-\(theme)"].waitForExistence(timeout: 8))
                capture("\(theme)-\(mode)-appearance")
                settings.terminate()
            }
        }
    }

    private func expand(_ app: XCUIApplication, _ title: String) {
        let text = app.navigationBars.staticTexts[title].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 8))
        if text.frame.minY > 120 {
            text.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
                thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)))
        }
    }

    private func capture(_ name: String) {
        Thread.sleep(forTimeInterval: 0.6)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
