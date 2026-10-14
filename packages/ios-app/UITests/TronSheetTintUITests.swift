import XCTest

/// Sheets of every family tint their toolbar icons like their titles (#963):
/// Settings and its indigo, cyan and emerald groups, the Automations and
/// Knowledge sheets, and Manage Home with a sub-sheet that takes its row's tint.
/// The paired-device sheet, reachable only with a real Gateway, is covered by
/// `RealGatewayPairAndChatUITests.testSettingsClarityPillsTextDoneAndAccountsFirst`.
final class TronSheetTintUITests: XCTestCase {
    @MainActor
    func testSettingsSheetToolbarsTakeTheirTitleTint() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-navigation-fixture"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["settings-link-Connections"].waitForExistence(timeout: 10), app.debugDescription)
        assertToolbarTint(app, title: "Settings")
        for title in ["Connections", "MCP Servers", "Appearance"] {
            let link = app.buttons["settings-link-\(title)"]
            for _ in 0..<12 where !link.isHittable { app.swipeUp() }
            link.tap()
            assertToolbarTint(app, title: title)
            app.buttons.matching(NSPredicate(format: "label == 'Done'")).allElementsBoundByIndex.last(where: \.isHittable)?.tap()
            XCTAssertTrue(app.navigationBars.staticTexts["Settings"].firstMatch.waitForExistence(timeout: 5))
            for _ in 0..<12 where !app.buttons["settings-link-Connections"].isHittable { app.swipeDown() }
        }
    }

    @MainActor
    func testDashboardSheetToolbarsTakeTheirTitleTint() {
        continueAfterFailure = false
        for (mode, action, title) in [("Automations", "Choose agenda date", "Jump to date"),
                                      ("Automations", "Create Automation", "New Automation"),
                                      ("Knowledge", "New note", "New note")] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-accessibility-fixture", "-fixture-dashboard"]
            app.launch(); defer { app.terminate() }
            let menu = app.buttons["dashboard.menu"]
            XCTAssertTrue(menu.waitForExistence(timeout: 10), app.debugDescription)
            menu.tap(); app.buttons[mode].tap()
            menu.tap(); app.buttons[action].tap()
            assertToolbarTint(app, title: title)
        }
    }

    @MainActor
    func testManageHomeToolbarsTakeTheirTitleTint() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        let ring = app.buttons["session-context-button"]
        XCTAssertTrue(ring.waitForExistence(timeout: 10))
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: ring)],
                                     timeout: 10) == .completed)
        ring.tap()
        XCTAssertTrue(app.buttons["home-sheet-done-manage"].waitForExistence(timeout: 10), app.debugDescription)
        assertToolbarTint(app, title: "Manage Home")
        let memory = app.descendants(matching: .any)["home-manage-memory-browser"].firstMatch
        XCTAssertTrue(memory.waitForExistence(timeout: 5), app.debugDescription)
        memory.tap()
        XCTAssertTrue(app.buttons["home-sheet-done-memory"].waitForExistence(timeout: 10), app.debugDescription)
        assertToolbarTint(app, title: "Memory")
    }
}
