import XCTest

/// Connected Services and MCP sheets against the in-app scripted connection owner.
/// Failure modes this E2E journey protects:
/// - a credit result from a previous profile/identity is published late;
/// - the delayed X credit read blocks the rest of the configured/available list;
/// - a failed X credit read leaves an error line in the list;
/// - a setup-required instance is incorrectly repeated under Available;
/// - an MCP server receives an X-only credit line.
final class TronIntegrationSheetsUITests: XCTestCase {
    @MainActor
    func testConfiguredAvailableCreditsAndDetails() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }

        XCTAssertTrue(app.staticTexts["Configured"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Raindrop"].exists)
        XCTAssertTrue(app.staticTexts["Jev"].exists)
        XCTAssertTrue(app.staticTexts["X"].exists)
        XCTAssertFalse(app.staticTexts["Jev tagging"].exists)
        XCTAssertTrue(app.staticTexts["MCP server"].exists == false)
        XCTAssertTrue(app.staticTexts["Setup required"].exists)
        XCTAssertTrue(app.staticTexts["Setup required"].exists, "Rows remain available while credits load")
        XCTAssertTrue(app.staticTexts.matching(identifier: "integration-credit-pending").firstMatch.waitForExistence(timeout: 2),
                      "The delayed X read reserves a pending row without blocking other entries")
        let credit = app.staticTexts["$4.20 available"]
        XCTAssertTrue(credit.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "MCP · $" )).firstMatch.exists)
        keepScreenshot(app, name: "c29-connected-services-light-x-credits")

        app.buttons["Details for X"].tap()
        XCTAssertTrue(app.staticTexts["Capabilities"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Read bookmarks"].exists)
        keepScreenshot(app, name: "c29-x-detail-light")
        app.buttons["Add another account for X"].tap()
        XCTAssertTrue(app.staticTexts["Set up X"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        app.terminate()

        let failing = launch(scenario: "credits-fail")
        defer { failing.terminate() }
        XCTAssertTrue(failing.staticTexts["Configured"].waitForExistence(timeout: 10))
        XCTAssertTrue(failing.staticTexts["Setup required"].exists)
        XCTAssertFalse(failing.staticTexts["$4.20 available"].waitForExistence(timeout: 4))
        XCTAssertTrue(failing.staticTexts["Raindrop"].exists, "Failed credits do not block other rows")
        keepScreenshot(failing, name: "c29-x-credit-failure-dark")
        failing.buttons["Details for Raindrop"].tap()
        XCTAssertTrue(failing.staticTexts["Capabilities"].waitForExistence(timeout: 5))
        XCTAssertTrue(failing.staticTexts["Raindrop collections"].waitForExistence(timeout: 3))
        XCTAssertTrue(failing.staticTexts["Research"].exists)
        keepScreenshot(failing, name: "c29-raindrop-detail-dark")
    }

    @MainActor
    func testMCPServerUsesConfiguredAvailableGroupsWithoutCredits() {
        continueAfterFailure = false
        let app = launch(surface: "mcp")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Configured"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Available"].exists)
        XCTAssertTrue(app.staticTexts["local-search"].exists)
        XCTAssertTrue(app.staticTexts["Remote MCP"].exists)
        XCTAssertFalse(app.staticTexts["Loading credits…"].exists)
        XCTAssertFalse(app.staticTexts["$4.20 available"].exists)
        app.buttons["Details for MCP server"].tap()
        XCTAssertTrue(app.staticTexts["Capabilities"].waitForExistence(timeout: 5))
        keepScreenshot(app, name: "c29-mcp-detail-dark")
        app.buttons["Cancel"].tap()
        app.buttons["Connect Remote MCP"].tap()
        XCTAssertTrue(app.staticTexts["Set up Remote MCP"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Remote endpoint"].exists)
    }

    @MainActor
    private func launch(scenario: String = "default", surface: String = "services") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-integrations-fixture", "-integrations-surface", surface, "-integrations-scenario", scenario,
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if scenario == "credits-fail" { app.launchArguments += ["-ui-dark-mode"] }
        app.launch()
        return app
    }

    @MainActor
    private func keepScreenshot(_ app: XCUIApplication, name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
