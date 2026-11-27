import XCTest

final class TronIntegrationSheetsUITests: XCTestCase {
    @MainActor
    private func launch(scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-integrations-fixture", "-integrations-scenario", scenario,
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
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
        waitLabel(state, "connected")
        XCTAssertEqual(app.staticTexts["primary-state"].label, primary)
        XCTAssertNotEqual(app.staticTexts["secondary-last-connected"].label, lastConnected)
        app.buttons["Lose secondary"].tap()
        waitFirstDelay("2.0,")
        keepScreenshot(app, name: "secondary-recovery-reset-simulator")
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
