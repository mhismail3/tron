import XCTest

/// Surviving provider layout and connection recovery against the hosted owner.
/// MCP add/auth authority and token handoff are covered by TronMCPServerSheetsUITests.
final class TronIntegrationSheetsUITests: XCTestCase {
    @MainActor
    func testOllamaUnlimitedAccessibilityAndTypeSizes() {
        for (size, largeType) in [("default", false), ("large", true)] {
            let app = launch(scenario: "ollama-detail", largeType: largeType)
            defer { app.terminate() }
            app.buttons["Details for Ollama"].tap()
            let cardLabel = "Unlimited. Local models run on this Mac with no account usage limits."
            let card = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", cardLabel)).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 5), app.debugDescription)
            keepScreenshot(app, name: "583-ollama-\(size)")
        }
    }

    @MainActor
    private func launch(scenario: String = "default", dark: Bool = false, largeType: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-integrations-fixture", "-integrations-scenario", scenario,
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if dark { app.launchArguments += ["-ui-dark-mode"] }
        if largeType {
            app.launchArguments += ["-fixture-large-type", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
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
    func testEstablishedSocketLossThenOpenTimeoutsBecomeUnreachable() {
        continueAfterFailure = false
        let app = launch(scenario: "connection-loss-unreachable")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Connected")).firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Mac unreachable")).firstMatch.waitForExistence(timeout: 30), app.debugDescription)
        keepScreenshot(app, name: "established-loss-unreachable-simulator")
    }

    @MainActor
    func testOpenedTransportFailureDoesNotClaimMacUnreachable() {
        let app = launch(scenario: "connection-opened-failure")
        defer { app.terminate() }
        let count = app.staticTexts["failed-socket-count"]
        let twoAttempts = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "failed sockets 2"), object: count)
        XCTAssertEqual(XCTWaiter.wait(for: [twoAttempts], timeout: 10), .completed)
        let reconnecting = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Connection status: Reconnecting")).firstMatch
        XCTAssertTrue(reconnecting.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Mac unreachable")).firstMatch.exists)
        app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Retry Connection")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Connection status: Connected")).firstMatch.waitForExistence(timeout: 10))
        keepScreenshot(app, name: "opened-transport-recovered-simulator")
    }

    @MainActor
    func testSecondaryRecoverySurvivesBackgroundAndResetsOnlyOnRetryOrSuccess() {
        continueAfterFailure = false
        let app = launch(scenario: "connection-secondary")
        defer { app.terminate() }
        let state = app.staticTexts["secondary-state"]
        func waitLabel(_ element: XCUIElement, _ value: String, timeout: TimeInterval = 10) {
            let predicate = NSPredicate(format: "label == %@", value)
            XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed, app.debugDescription)
        }
        waitLabel(state, "connected")
        let primary = app.staticTexts["primary-state"].label
        let lastConnected = app.staticTexts["secondary-last-connected"].label
        XCTAssertTrue(lastConnected.hasPrefix("last connected "))
        app.buttons["Lose secondary"].tap()
        waitLabel(state, "offline")
        waitLabel(app.staticTexts["secondary-delay"], "wait 300.0")
        XCTAssertEqual(app.staticTexts["secondary-last-connected"].label, lastConnected)
        XCUIDevice.shared.press(.home)
        app.activate()
        waitLabel(state, "offline")
        let waits = app.staticTexts["secondary-waits"]
        func waitFirstDelay(_ value: String) {
            let predicate = NSPredicate(format: "label BEGINSWITH %@", value)
            XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: waits)], timeout: 5) == .completed, app.debugDescription)
        }
        waitFirstDelay("300.0,")
        XCTAssertEqual(app.staticTexts["secondary-last-connected"].label, lastConnected)
        XCTAssertEqual(app.staticTexts["primary-state"].label, primary)
        app.buttons["Retry secondary"].tap()
        waitFirstDelay("2.0,")
        app.buttons["Restore secondary"].tap()
        // Automatic success, without another Retry, must reset the next outage.
        waitLabel(state, "connected")
        XCTAssertEqual(app.staticTexts["primary-state"].label, primary)
        XCTAssertNotEqual(app.staticTexts["secondary-last-connected"].label, lastConnected)
        app.buttons["Lose secondary"].tap()
        waitFirstDelay("2.0,")
        keepScreenshot(app, name: "secondary-recovery-reset-simulator")
    }

    @MainActor
    private func assertRetryRecovers(scenario: String) {
        continueAfterFailure = false
        do {
            let app = launch(scenario: scenario)
            defer { app.terminate() }
            let state = scenario == "connection-unreachable" ? "Mac unreachable" : "Reconnecting"
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", state)).firstMatch.waitForExistence(timeout: 30), app.debugDescription)
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
