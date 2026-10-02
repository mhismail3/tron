import XCTest

/// Connected Services sheets against the in-app scripted connection owner.
/// Failure modes this E2E journey protects:
/// - the delayed X credit read blocks the rest of the configured/available list;
/// - a failed X credit read leaves an error line in the list;
/// - a setup-required instance is incorrectly repeated under Available.
final class TronIntegrationSheetsUITests: XCTestCase {
    /// Replacing the foreground transport must not destroy an unsubmitted form.
    @MainActor
    func testXSetupDraftSurvivesBackgroundReconnect() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Details for X"].waitForExistence(timeout: 10))
        app.buttons["Details for X"].tap()
        app.buttons["Add another account for X"].tap()
        XCTAssertTrue(app.staticTexts["Set up X"].waitForExistence(timeout: 5))
        let client = app.textFields.element(boundBy: 0)
        client.tap(); client.typeText("fixture-public-client")
        let callback = app.textFields.element(boundBy: 1)
        callback.tap(); callback.typeText("https://example.test/callback")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.staticTexts["Set up X"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(client.value as? String, "fixture-public-client")
        XCTAssertEqual(callback.value as? String, "https://example.test/callback")
        keepScreenshot(app, name: "348-x-draft-after-background-reconnect")
    }

    @MainActor
    func testAcceptedXBeginResolvesOriginalReceiptAfterBackground() {
        continueAfterFailure = false
        let app = launch(scenario: "oauth-delayed")
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Details for X"].waitForExistence(timeout: 10))
        app.buttons["Details for X"].tap()
        app.buttons["Add another account for X"].tap()
        XCTAssertTrue(app.staticTexts["Set up X"].waitForExistence(timeout: 5))
        app.textFields.element(boundBy: 0).tap()
        app.textFields.element(boundBy: 0).typeText("fixture-public-client")
        app.textFields.element(boundBy: 1).tap()
        app.textFields.element(boundBy: 1).typeText("https://example.test/callback")
        app.buttons["Authorize X"].tap()
        XCTAssertTrue(app.staticTexts["Completing setup…"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["Complete setup"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.buttons["Open X consent"].exists)
        XCTAssertEqual(app.textFields.element(boundBy: 0).value as? String, "fixture-public-client")
        keepScreenshot(app, name: "348-accepted-x-begin-recovered-from-receipt")
    }

    @MainActor
    func testConfiguredAvailableCreditsAndDetails() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }

        XCTAssertTrue(app.staticTexts["Configured"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Raindrop"].exists)
        XCTAssertFalse(app.staticTexts["Available"].exists, "Configured services must not be duplicated in Available")
        XCTAssertTrue(app.staticTexts["X"].exists)
        XCTAssertTrue(app.staticTexts["Account"].exists)
        XCTAssertTrue(app.staticTexts["Setup required"].exists)
        XCTAssertTrue(app.staticTexts["Setup required"].exists, "Rows remain available while credits load")
        XCTAssertTrue(app.staticTexts.matching(identifier: "integration-credit-pending").firstMatch.waitForExistence(timeout: 2),
                      "The delayed X read reserves a pending row without blocking other entries")
        let credit = app.staticTexts["$4.20 available"]
        XCTAssertTrue(credit.waitForExistence(timeout: 10), app.debugDescription)
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
        failing.buttons.matching(identifier: "Details for Raindrop").firstMatch.tap()
        XCTAssertTrue(failing.staticTexts["Capabilities"].waitForExistence(timeout: 5))
        XCTAssertTrue(failing.staticTexts["Raindrop collections"].waitForExistence(timeout: 3))
        XCTAssertTrue(failing.staticTexts["Research home"].exists)
        XCTAssertTrue(failing.staticTexts["Collection 63441068"].exists)
        keepScreenshot(failing, name: "c29-raindrop-detail-dark")
        let lightRaindrop = launch(scenario: "credits-fail-light")
        defer { lightRaindrop.terminate() }
        XCTAssertTrue(lightRaindrop.staticTexts["Configured"].waitForExistence(timeout: 10))
        lightRaindrop.buttons.matching(identifier: "Details for Raindrop").firstMatch.tap()
        XCTAssertTrue(lightRaindrop.staticTexts["Raindrop collections"].waitForExistence(timeout: 5))
        keepScreenshot(lightRaindrop, name: "c29-raindrop-detail-light")
    }

    @MainActor
    private func launch(scenario: String = "default", dark: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-integrations-fixture", "-integrations-scenario", scenario,
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if dark { app.launchArguments += ["-ui-dark-mode"] }
        app.launch()
        return app
    }

    @MainActor
    func testRetryConnectionRecoversReconnectingDetails() {
        assertRetryRecovers(scenario: "connection-retry")
    }

    @MainActor
    func testRetryConnectionRecoversUnreachableDetails() {
        assertRetryRecovers(scenario: "connection-unreachable")
    }

    @MainActor
    private func assertRetryRecovers(scenario: String) {
        continueAfterFailure = false
        do {
            let app = launch(scenario: scenario)
            defer { app.terminate() }
            let state = scenario == "connection-unreachable" ? "Mac unreachable" : "Reconnecting"
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", state)).firstMatch.waitForExistence(timeout: 10), app.debugDescription)
            let retry = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Retry Connection")).firstMatch
            XCTAssertTrue(retry.waitForExistence(timeout: 3), app.debugDescription)
            keepScreenshot(app, name: "\(scenario)-retry-available")
            retry.tap()
            XCTAssertTrue(app.otherElements["Connection status: Connected"].waitForExistence(timeout: 5)
                || app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Connection status: Connected")).firstMatch.exists,
                "Retry must interrupt the parked delay and admit a replacement socket: \(app.debugDescription)")
            XCTAssertFalse(retry.exists)
            keepScreenshot(app, name: "\(scenario)-recovered")
            app.terminate()
        }
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
