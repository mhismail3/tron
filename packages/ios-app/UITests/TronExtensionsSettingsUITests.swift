import XCTest

/// Global Extensions over the production Settings sheet path, with the
/// Gateway's package shape: five configured Mac packages plus the bundled
/// managed provider `packages.list` appends (#1482).
final class TronExtensionsSettingsUITests: XCTestCase {
    @MainActor
    private func openExtensions(dark: Bool = false, large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-ui-extensions",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if dark { app.launchArguments.append("-settings-renderer-dark") }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"] }
        app.launch()
        let link = app.buttons["settings-link-Extensions"]
        XCTAssertTrue(link.waitForExistence(timeout: 15), app.debugDescription)
        for _ in 0..<8 where !link.isHittable { app.swipeUp() }
        link.tap()
        XCTAssertTrue(app.staticTexts["Installed"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["npm:pi-web-access"].waitForExistence(timeout: 10), app.debugDescription)
        return app
    }

    @MainActor
    private func keep(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Captures the whole sheet, top to the Search paths group, per appearance.
    @MainActor
    func testExtensionsSheetCaptures() {
        for (name, dark, large) in [("light", false, false), ("dark", true, false), ("large", false, true)] {
            let app = openExtensions(dark: dark, large: large)
            let searchPaths = app.staticTexts["Search paths"]
            var reachedEnd = false
            for page in 0..<(large ? 14 : 6) {
                keep(app, "1482-extensions-\(name)-\(page)")
                if reachedEnd { break }
                reachedEnd = searchPaths.exists && searchPaths.isHittable
                app.swipeUp(velocity: .slow)
            }
            app.terminate()
        }
    }
}
