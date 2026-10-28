import XCTest

/// A real Gateway/Pi install and fresh runner load, not a fixture key/value store.
final class TronInstalledSwiftAppUITests: XCTestCase {
    @MainActor
    func testInstalledValuesSurviveRunnerCloseAndReopen() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard environment["TRON_E2E_PORT"] != nil, environment["TRON_E2E_CODE"] != nil,
              environment["TRON_E2E_WORKSPACE"] != nil else {
            throw XCTSkip("Run through scripts/ios-gateway-e2e-test run-ui.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-tron-installed-swift-app-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        for key in ["TRON_E2E_PORT", "TRON_E2E_CODE", "TRON_E2E_WORKSPACE"] { app.launchEnvironment[key] = environment[key] }
        app.launch()
        defer { app.terminate() }
        let open = app.buttons["installed.open"]
        XCTAssertTrue(wait(open, "enabled == true"), app.debugDescription)
        open.tap()
        XCTAssertTrue(app.staticTexts["Count 0"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["Add entry"].tap()
        XCTAssertTrue(app.staticTexts["Count 1"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Saved 1"].exists)
        XCTAssertTrue(app.staticTexts["Transient 1"].exists)
        keep(app, "installed-before-close")
        app.buttons["Done"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(app.staticTexts["installed.saveStatus"], "label == 'Saved revision 1'"), app.debugDescription)
        open.tap()
        XCTAssertTrue(app.staticTexts["Count 1"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Saved 1"].exists)
        XCTAssertTrue(app.staticTexts["Transient 0"].exists, "A fresh runtime resets @State, not Gateway-backed wrappers")
        app.buttons["Reject action"].tap()
        XCTAssertTrue(app.staticTexts["Count 1"].exists)
        XCTAssertTrue(app.staticTexts["Saved 1"].exists)
        XCTAssertTrue(app.staticTexts["Transient 0"].exists)
        keep(app, "installed-after-reopen-and-rollback")
        app.buttons["Done"].tap()
        XCTAssertTrue(wait(app.staticTexts["installed.saveStatus"], "label == 'Saved revision 1'"), "A rolled-back action must not commit")
        open.tap()
        XCTAssertTrue(app.staticTexts["Count 1"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Saved 1"].exists)
        XCTAssertTrue(app.staticTexts["Transient 0"].exists)
        app.buttons["Done"].tap()
    }

    @MainActor
    private func wait(_ element: XCUIElement, _ predicate: String) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)], timeout: 20) == .completed
    }

    @MainActor
    private func keep(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
