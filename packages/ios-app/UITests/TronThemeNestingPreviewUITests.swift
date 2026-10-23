import XCTest

/// Native navigation captures for visual review only, not regression acceptance.
@MainActor final class TronThemeNestingPreviewUITests: XCTestCase {
    func testEmeraldLight() { capture(theme: "emerald", dark: false) }
    func testEmeraldDark() { capture(theme: "emerald", dark: true) }
    func testBurgundyLight() { capture(theme: "burgundy", dark: false) }
    func testBurgundyDark() { capture(theme: "burgundy", dark: true) }

    private func capture(theme: String, dark: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-memory-redesign", "-dashboard-view-home", "-themeColor", theme]
            + (dark ? ["-home-dark"] : [])
        app.launch()
        XCTAssertTrue(element(app, "home-usage-card").waitForExistence(timeout: 15))
        shot("usage")
        app.buttons["home-pinned-row"].tap()
        XCTAssertTrue(app.buttons["session-context-button"].waitForExistence(timeout: 10))
        shot("composer-context")
        app.buttons["session-context-button"].tap()
        XCTAssertTrue(element(app, "home-manage-state").waitForExistence(timeout: 8))
        expand(app, "Manage Home")
        app.buttons["home-manage-memory-browser"].tap()
        XCTAssertTrue(app.buttons["home-memory-row-39"].waitForExistence(timeout: 8))
        expand(app, "Memory")
        shot("memory-icons")
        app.buttons["home-memory-row-39"].tap()
        XCTAssertTrue(element(app, "home-memory-detail").waitForExistence(timeout: 8))
        expand(app, "Memory Entry")
        shot("memory-entry")
        app.terminate()

        app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-changes-review", "-themeColor", theme]
            + (dark ? ["-settings-renderer-dark"] : [])
        app.launch()
        XCTAssertTrue(app.buttons["Changes"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["Changes"].firstMatch.tap()
        XCTAssertTrue(app.buttons["settings-change-review-0"].waitForExistence(timeout: 10))
        expand(app, "Changes")
        shot("changes")
        app.terminate()
    }
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func expand(_ app: XCUIApplication, _ title: String) {
        let heading = app.navigationBars.staticTexts[title].firstMatch
        // Use the visible navigation bar, regardless of the destination's title copy.
        let handle = heading.exists ? heading : app.navigationBars.firstMatch
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)))
    }
    private func shot(_ name: String) {
        Thread.sleep(forTimeInterval: 0.7)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
