import XCTest

/// Navigation-only native captures for visual approval, not regression acceptance.
@MainActor final class TronThemeColorPreviewUITests: XCTestCase {
    func testEmeraldHome() { home("emerald") }
    func testBurgundyHome() { home("burgundy") }
    func testOliveGoldHome() { home("oliveGold") }
    func testEmeraldAppearanceAndNewSession() { settings("emerald"); newSession("emerald") }
    func testBurgundyAppearanceAndNewSession() { settings("burgundy"); newSession("burgundy") }
    func testOliveGoldAppearanceAndNewSession() { settings("oliveGold"); newSession("oliveGold") }
    func testTranscriptAndFirstOpenEditors() {
        for mode in ["light", "dark"] {
            let app = launch(["-tron-home-dashboard-fixture", "-home-shell-ready", "-memory-redesign"] + (mode == "dark" ? ["-home-dark"] : []), "emerald")
            manage(app)
            for (control, slider) in [("Effort", "settings-choice-slider"), ("Context Window", "settings-number-slider")] {
                app.buttons[control].firstMatch.tap()
                _ = app.descendants(matching: .any)[slider].firstMatch.waitForExistence(timeout: 5)
                shot("first-open-\(control)-\(mode)")
                app.buttons["home-sheet-done-manage"].tap()
            }
            tap(app, "home-manage-memory-browser")
            expand(app, "Memory")
            tap(app, "home-memory-row-38")
            tap(app, "home-memory-canonical-transcript")
            XCTAssertTrue(element(app, "home-evidence-text").waitForExistence(timeout: 8), app.debugDescription)
            shot("canonical-transcript-\(mode)")
            app.terminate()
        }
    }
    private func home(_ theme: String) {
        for mode in ["light", "dark"] {
            let app = launch(["-tron-home-dashboard-fixture", "-home-shell-ready", "-settings-scope-review"] + (mode == "dark" ? ["-home-dark"] : []), theme)
            XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 15)); app.buttons["home-pinned-row"].tap()
            XCTAssertTrue(app.buttons["session-context-button"].waitForExistence(timeout: 10))
            shot("\(theme)-chat-\(mode)")
            app.buttons["session-context-button"].tap()
            XCTAssertTrue(element(app, "home-manage-state").waitForExistence(timeout: 8)); expand(app, "Manage Home")
            shot("\(theme)-manage-home-\(mode)")
            tap(app, "home-manage-settings"); expand(app, "Home Settings")
            shot("\(theme)-home-settings-\(mode)")
            app.terminate()
        }
    }
    private func settings(_ theme: String) {
        for mode in ["light", "dark"] {
            let app = launch(["-tron-settings-renderer-fixture", "-settings-nested", "-settings-expanded-review"] + (mode == "dark" ? ["-settings-renderer-dark"] : []), theme)
            XCTAssertTrue(app.buttons["Open Settings"].waitForExistence(timeout: 15)); app.buttons["Open Settings"].tap()
            expand(app, "Global Settings"); tap(app, "Appearance"); expand(app, "Appearance")
            shot("\(theme)-appearance-\(mode)")
            app.terminate()
        }
    }
    private func newSession(_ theme: String) {
        for mode in ["light", "dark"] {
            let app = launch(["-tron-new-session-fixture", "-new-session-scenario", "project-settings", "-fixture-appearance", mode], theme)
            XCTAssertTrue(app.buttons["new-session-card.Source Control"].waitForExistence(timeout: 15))
            shot("\(theme)-new-session-\(mode)")
            app.buttons["new-session-card.Source Control"].tap()
            XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 8))
            shot("\(theme)-source-control-\(mode)")
            app.terminate()
        }
    }
    private func launch(_ args: [String], _ theme: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = args + ["-themeColor", theme]; app.launch(); return app
    }
    private func manage(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 15)); app.buttons["home-pinned-row"].tap()
        XCTAssertTrue(app.buttons["session-context-button"].waitForExistence(timeout: 10)); app.buttons["session-context-button"].tap()
        XCTAssertTrue(element(app, "home-manage-state").waitForExistence(timeout: 8)); expand(app, "Manage Home")
    }
    private func tap(_ app: XCUIApplication, _ id: String) {
        let target = element(app, id)
        for _ in 0..<6 where !target.isHittable { app.swipeUp() }
        XCTAssertTrue(target.waitForExistence(timeout: 8), app.debugDescription); target.tap()
    }
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private func expand(_ app: XCUIApplication, _ title: String) {
        let text = app.navigationBars.staticTexts[title].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 8), app.debugDescription)
        if text.frame.minY > 120 {
            text.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
                thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)))
        }
    }
    private func shot(_ name: String) {
        Thread.sleep(forTimeInterval: 0.6)
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
}
