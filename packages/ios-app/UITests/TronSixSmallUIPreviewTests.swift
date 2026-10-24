import XCTest

/// Navigation/capture only; these are not behavioral acceptance tests.
@MainActor final class TronSixSmallUIPreviewTests: XCTestCase {
    func testHome() { capture("home") }
    func testSession() { capture("session") }
    func testModels() { capture("models") }
    func testToast() { capture("toast") }
    func testWorkspace() { capture("workspace") }
    func testCheckin() { capture("checkin") }
    func testCheckinBlocked() { capture("checkin-blocked") }
    func testWorkspaceAccessibility() { capture("workspace", extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]) }

    func testWorkspaceNarrow() { capture("workspace", extra: ["-six-ui-narrow"]) }

    private func capture(_ surface: String, extra: [String] = []) {
        continueAfterFailure = false
        for mode in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-expanded-review", "-six-ui-surface", surface,
                                   "-themeColor", "burgundy", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extra
            if mode == "dark" { app.launchArguments.append("-settings-renderer-dark") }
            app.launch()
            XCTAssertTrue(app.buttons["Done"].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
            if surface == "home" { XCTAssertTrue(app.buttons["Models"].firstMatch.waitForExistence(timeout: 8), app.debugDescription) }
            if surface == "session" { XCTAssertTrue(app.buttons["Project Trust"].firstMatch.waitForExistence(timeout: 8), app.debugDescription) }
            if surface == "workspace" { XCTAssertTrue(app.staticTexts["Clean"].firstMatch.waitForExistence(timeout: 8), app.debugDescription) }
            if surface == "toast" { XCTAssertTrue(app.staticTexts["in-app-notice-card"].firstMatch.waitForExistence(timeout: 8), app.debugDescription) }
            Thread.sleep(forTimeInterval: 1)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "\(surface)-\(extra.isEmpty ? "standard" : extra.contains("-six-ui-narrow") ? "narrow" : "large-type")-\(mode)"
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
    }
}
