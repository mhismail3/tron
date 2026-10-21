import XCTest

/// Real rendered Manage Home controls in both supported appearances.
final class TronHomeControlsUITests: XCTestCase {
    /// Compare rendered glyph colors, not a test-only accessibility style label.
    @MainActor func testDisableHomeSubtitleMatchesDestructiveTitle() {
        continueAfterFailure = false
        for mode in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
                + (mode == "dark" ? ["-home-dark"] : [])
            app.launch()
            XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 15))
            app.buttons["home-pinned-row"].tap()
            let ring = app.buttons["session-context-button"]
            XCTAssertTrue(waitFor(ring, "enabled == true"))
            open(app, ring, ready: "home-manage-state", name: "manage")
            expand(app, done: "home-sheet-done-manage")
            let disable = element(app, "home-manage-disable")
            for _ in 0..<5 where !disable.isHittable || disable.frame.maxY > app.frame.maxY - 50 {
                app.swipeUp()
            }
            XCTAssertTrue(disable.isHittable)
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "disable-home-subtitle-\(mode)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            // Default-size labels occupy separate halves of this two-line row.
            // Exclude the leading icon so it cannot make a neutral subtitle pass.
            let title = ink(app, disable, crop: { frame in
                CGRect(x: frame.minX + 56, y: frame.minY,
                       width: frame.width - 56, height: frame.height / 2)
            })
            let subtitle = ink(app, disable, crop: { frame in
                CGRect(x: frame.minX + 56, y: frame.midY,
                       width: frame.width - 56, height: frame.height / 2)
            })
            XCTAssertGreaterThan(title[0] - max(title[1], title[2]), 0.3, "Destructive title is red in \(mode)")
            XCTAssertLessThan(zip(title, subtitle).map { abs($0 - $1) }.max()!, 0.12,
                              "Disable Home's subtitle matches its destructive title in \(mode): \(subtitle) vs \(title)")
            app.terminate()
        }
    }

}
