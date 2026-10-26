import XCTest

/// Restores the approved dashboard and top-level settings section anatomy.
@MainActor
final class TronDashboardHeadersRegressionUITests: XCTestCase {
    func testDashboardHeadersAndSpacing() {
        for dark in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-dashboard-workers", "-dashboard-view-home"] + (dark ? ["-home-dark"] : [])
            app.launch()
            defer { app.terminate() }
            let row = app.buttons["session-row-home-shell-fixture:worker-running"]
            XCTAssertTrue(row.waitForExistence(timeout: 15))
            Thread.sleep(forTimeInterval: 2)
            capture("dashboard-\(dark ? "dark" : "light")")
            let heading = app.staticTexts["In Progress"]
            let completed = app.staticTexts["Recently Completed"]
            XCTAssertTrue(heading.exists, app.debugDescription)
            XCTAssertTrue(completed.exists, app.debugDescription)
            if heading.exists && completed.exists {
                XCTAssertEqual(row.frame.minY - heading.frame.maxY, 0, accuracy: 1, "Keep the approved header-to-row layout")
                XCTAssertGreaterThan(completed.frame.minY - row.frame.maxY, 15, "Keep distinct sections, not an undifferentiated row stack")
                let geometry = XCTAttachment(string: "header=\(heading.frame); row=\(row.frame); completed=\(completed.frame)")
                geometry.name = "dashboard-geometry-\(dark ? "dark" : "light")"
                geometry.lifetime = .keepAlways
                add(geometry)
            }
            app.terminate()
        }
    }

    func testGlobalSettingsGroupHeaders() {
        for dark in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-nested", "-settings-expanded-review", "-fixture-appearance", dark ? "dark" : "light"]
            app.launch()
            defer { app.terminate() }
            let open = app.buttons["Open Settings"]
            XCTAssertTrue(open.waitForExistence(timeout: 15))
            open.tap()
            XCTAssertTrue(app.buttons["Appearance"].waitForExistence(timeout: 8))
            Thread.sleep(forTimeInterval: 1)
            capture("global-settings-\(dark ? "dark" : "light")-top")
            for title in ["This iPhone", "Accounts", "Agent & Tools", "System"] {
                let heading = app.staticTexts[title].firstMatch
                for _ in 0..<5 where !heading.isHittable { app.swipeUp() }
                XCTAssertTrue(heading.exists, "Missing Global Settings group: \(title)\n\(app.debugDescription)")
            }
            capture("global-settings-\(dark ? "dark" : "light")-bottom")
            app.terminate()
        }
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
