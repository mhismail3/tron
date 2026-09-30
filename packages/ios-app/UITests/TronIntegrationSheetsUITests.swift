import XCTest

/// Connected Services and MCP sheets against the in-app scripted connection owner.
/// Failure modes this E2E journey protects:
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
        XCTAssertEqual(app.staticTexts.matching(identifier: "Jev").count, 1)
        XCTAssertFalse(app.staticTexts["Available"].exists, "Configured services must not be duplicated in Available")
        XCTAssertTrue(app.staticTexts["X"].exists)
        XCTAssertFalse(app.staticTexts["Jev tagging"].exists)
        XCTAssertFalse(app.staticTexts["jev-account"].exists)
        XCTAssertTrue(app.staticTexts["Account"].exists)
        XCTAssertTrue(app.staticTexts["MCP server"].exists == false)
        XCTAssertTrue(app.staticTexts["Setup required"].exists)
        XCTAssertTrue(app.staticTexts["Setup required"].exists, "Rows remain available while credits load")
        XCTAssertTrue(app.staticTexts.matching(identifier: "integration-credit-pending").firstMatch.waitForExistence(timeout: 2),
                      "The delayed X read reserves a pending row without blocking other entries")
        let credit = app.staticTexts["$4.20 available"]
        XCTAssertTrue(credit.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "MCP · $" )).firstMatch.exists)
        keepScreenshot(app, name: "c29-connected-services-light-x-credits")
        let darkServices = launch(scenario: "credits-dark", dark: true)
        defer { darkServices.terminate() }
        XCTAssertTrue(darkServices.staticTexts["$4.20 available"].waitForExistence(timeout: 10))
        keepScreenshot(darkServices, name: "c29-connected-services-dark-x-credits")

        app.buttons["Details for X"].tap()
        XCTAssertTrue(app.staticTexts["Capabilities"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Read bookmarks"].exists)
        keepScreenshot(app, name: "c29-x-detail-light")
        let darkX = launch(scenario: "credits-dark", dark: true)
        defer { darkX.terminate() }
        XCTAssertTrue(darkX.staticTexts["$4.20 available"].waitForExistence(timeout: 10))
        darkX.buttons["Details for X"].tap()
        XCTAssertTrue(darkX.staticTexts["Capabilities"].waitForExistence(timeout: 5))
        keepScreenshot(darkX, name: "c29-x-detail-dark")
        app.buttons["Add another account for X"].tap()
        XCTAssertTrue(app.staticTexts["Set up X"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        app.terminate()

        let failing = launch(scenario: "credits-fail")
        defer { failing.terminate() }
        XCTAssertTrue(failing.staticTexts["Configured"].waitForExistence(timeout: 10))
        XCTAssertTrue(failing.staticTexts["Setup required"].exists)
        XCTAssertFalse(failing.staticTexts["$4.20 available"].waitForExistence(timeout: 10))
        XCTAssertFalse(failing.staticTexts.matching(identifier: "integration-credit-pending").firstMatch.exists)
        XCTAssertFalse(failing.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "error")).firstMatch.exists)
        XCTAssertFalse(failing.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "failed")).firstMatch.exists)
        XCTAssertTrue(failing.staticTexts["Raindrop"].exists, "Failed credits do not block other rows")
        keepScreenshot(failing, name: "c29-x-credit-failure-dark")
        failing.buttons["Details for Raindrop"].tap()
        XCTAssertTrue(failing.staticTexts["Capabilities"].waitForExistence(timeout: 5))
        XCTAssertTrue(failing.staticTexts["Raindrop collections"].waitForExistence(timeout: 3))
        XCTAssertTrue(failing.staticTexts["Research home"].exists)
        XCTAssertTrue(failing.staticTexts["Collection 63441068"].exists)
        keepScreenshot(failing, name: "c29-raindrop-detail-dark")
        let lightRaindrop = launch(scenario: "credits-fail-light")
        defer { lightRaindrop.terminate() }
        XCTAssertTrue(lightRaindrop.staticTexts["Configured"].waitForExistence(timeout: 10))
        lightRaindrop.buttons["Details for Raindrop"].tap()
        XCTAssertTrue(lightRaindrop.staticTexts["Raindrop collections"].waitForExistence(timeout: 5))
        keepScreenshot(lightRaindrop, name: "c29-raindrop-detail-light")
    }

    @MainActor
    func testMCPServerUsesConfiguredAvailableGroupsWithoutCredits() {
        continueAfterFailure = false
        let light = launch(surface: "mcp")
        defer { light.terminate() }
        XCTAssertTrue(light.staticTexts["Configured"].waitForExistence(timeout: 10))
        keepScreenshot(light, name: "c29-mcp-servers-light")
        let app = launch(surface: "mcp", dark: true)
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Configured"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Available"].exists)
        XCTAssertTrue(app.staticTexts["local-search"].exists)
        keepScreenshot(app, name: "c29-mcp-servers-dark")
        XCTAssertTrue(app.buttons["Add another server for MCP server"].exists)
        XCTAssertTrue(app.staticTexts["Not configured"].exists, "An addable service reads like Providers' Available rows")
        XCTAssertFalse(app.staticTexts["Setup required"].exists, "Setup required is reserved for a configured account needing attention")
        XCTAssertFalse(app.staticTexts["Remote MCP"].exists)
        XCTAssertFalse(app.staticTexts["Loading credits…"].exists)
        XCTAssertFalse(app.staticTexts["$4.20 available"].exists)
        app.buttons["Details for MCP server"].tap()
        XCTAssertTrue(app.staticTexts["Capabilities"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Add another server for MCP server"].exists)
        keepScreenshot(app, name: "c29-mcp-detail-dark")
        app.buttons["Cancel"].tap()
        app.buttons["Add another server for MCP server"].tap()
        XCTAssertTrue(app.staticTexts["Set up MCP server"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Remote endpoint"].exists)
    }

    @MainActor
    private func launch(scenario: String = "default", surface: String = "services", dark: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-integrations-fixture", "-integrations-surface", surface, "-integrations-scenario", scenario,
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if dark { app.launchArguments += ["-ui-dark-mode"] }
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
