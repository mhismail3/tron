import XCTest

/// Production card and admin navigation on a simulator, over hosted socket data.
/// Gateway native-change E2Es own effect authorization, expiry and Undo.
@MainActor
final class TronD4ReviewUITests: XCTestCase {
    func testSharedCardLight() { card(mode: "light", large: false) }
    func testSharedCardDark() { card(mode: "dark", large: false) }
    func testSharedCardLightXXXL() { card(mode: "light", large: true) }
    func testSharedCardDarkXXXL() { card(mode: "dark", large: true) }
    func testAdminLight() { admin(mode: "light", large: false) }
    func testAdminDark() { admin(mode: "dark", large: false) }
    func testAdminLightXXXL() { admin(mode: "light", large: true) }
    func testAdminDarkXXXL() { admin(mode: "dark", large: true) }

    private func arguments(mode: String, large: Bool) -> [String] {
        ["-themeColor", "burgundy", "-appearanceMode", mode,
         "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            + (large ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : [])
    }

    private func card(mode: String, large: Bool) {
        continueAfterFailure = false
        for approved in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-ask-user-fixture", "-tron-native-change-fixture"]
                + arguments(mode: mode, large: large)
            app.launch()
            defer { app.terminate() }
            expand(app, title: "Review change")
            XCTAssertTrue(app.staticTexts["Mutation count: 0"].exists, "Opening review must not answer")
            XCTAssertTrue(app.staticTexts["Before"].firstMatch.exists)
            XCTAssertFalse(app.buttons["Submit all answers"].exists)
            keep(app, "card-\(mode)\(large ? "-xxxl" : "")-top")
            let button = app.buttons[approved ? "Approve" : "Cancel"]
            for _ in 0..<8 where !button.isHittable { app.swipeUp() }
            XCTAssertTrue(button.isHittable, app.debugDescription)
            XCTAssertTrue(app.staticTexts["printf 'native witness'"].exists)
            keep(app, "card-\(mode)\(large ? "-xxxl" : "")-actions")
            button.tap()
            let expected = "native change approved=\(approved) digest=\(String(repeating: "a", count: 64)) scope=ask-user-interaction/hosted-ask-user-epoch/1"
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", expected)).firstMatch.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(app.staticTexts["Mutation count: 1"].exists, "Exactly one response, not proof of a Gateway effect")
        }
    }

    private func admin(mode: String, large: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-nested", "-settings-expanded-review"]
            + arguments(mode: mode, large: large)
            + (mode == "dark" ? ["-settings-renderer-dark"] : [])
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Open Settings"].waitForExistence(timeout: 10))
        app.buttons["Open Settings"].tap()
        expand(app, title: "Global Settings")
        let agent = app.buttons["settings-link-Agent Behavior"]
        for _ in 0..<8 where !agent.isHittable { app.swipeUp() }
        XCTAssertTrue(agent.isHittable, app.debugDescription)
        keep(app, "admin-\(mode)\(large ? "-xxxl" : "")")
        agent.tap()
        expand(app, title: "Agent Behavior")
        XCTAssertTrue(app.staticTexts["Model"].firstMatch.exists, app.debugDescription)
        keep(app, "agent-\(mode)\(large ? "-xxxl" : "")")
    }

    private func expand(_ app: XCUIApplication, title: String) {
        let heading = app.navigationBars.staticTexts[title].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 10), app.debugDescription)
        if heading.frame.minY > 120 {
            heading.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)))
        }
    }

    private func keep(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "2173-d4-simulator-\(name)"; shot.lifetime = .keepAlways; add(shot)
    }
}
