import XCTest

final class TronProjectTrustUITests: XCTestCase {
    @MainActor
    func testBackgroundReconciliationKeepsLatestBlockWithoutResending() {
        let app = launch(scenario: "held")
        defer { app.terminate() }
        acceptTrustThenBlock(app)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(counts(app, contain: "queries:1"), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Resources blocked"].waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["fixture.release-trust"].tap()
        assertBlockedWithoutLateTrust(app, screenshot: "358-trust-latest-block-after-background")
        assertOriginalCommands(app, count: 2)
    }

    @MainActor
    private func acceptTrustThenBlock(_ app: XCUIApplication) {
        app.buttons["Trust Project"].tap()
        XCTAssertTrue(counts(app, contain: "held:1"), app.debugDescription)
        XCTAssertTrue(app.buttons["Do Not Load Project Resources"].waitForExistence(timeout: 10))
        app.buttons["Do Not Load Project Resources"].tap()
        XCTAssertTrue(counts(app, contain: "sets:2 commands:2 repeats:0"), app.debugDescription)
        XCTAssertTrue(positiveCount(app, field: "readsFalse"), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Resources blocked"].waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor
    private func assertBlockedWithoutLateTrust(_ app: XCUIApplication, screenshot: String) {
        let stale = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: app.staticTexts["Trusted"])
        let observed = XCTWaiter.wait(for: [stale], timeout: 2)
        keepScreenshot(app, name: screenshot)
        XCTAssertEqual(observed, .timedOut, "An earlier accepted trust receipt must not replace the latest canonical inspection")
        XCTAssertTrue(app.staticTexts["Resources blocked"].exists, app.debugDescription)
    }

    @MainActor
    private func assertOriginalCommands(_ app: XCUIApplication, count: Int) {
        XCTAssertTrue(counts(app, contain: "sets:\(count) commands:\(count) repeats:0"), app.debugDescription)
        XCTAssertTrue(counts(app, contain: "wrongCWD:0"))
    }

    @MainActor
    private func positiveCount(_ app: XCUIApplication, field: String, id: String = "fixture.trust-original") -> Bool {
        let condition = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label MATCHES %@", ".*\\b\(field):[1-9][0-9]*\\b.*"),
                                                  object: app.staticTexts[id])
        return XCTWaiter.wait(for: [condition], timeout: 15) == .completed
    }

    @MainActor
    private func counts(_ app: XCUIApplication, id: String = "fixture.trust-original", contain expected: String) -> Bool {
        let condition = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", expected), object: app.staticTexts[id])
        return XCTWaiter.wait(for: [condition], timeout: 15) == .completed
    }

    @MainActor
    private func launch(scenario: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-project-trust-fixture", "-project-trust-scenario", scenario]
        app.launch()
        XCTAssertTrue(app.staticTexts["Decision needed"].waitForExistence(timeout: 15), app.debugDescription)
        return app
    }

    @MainActor
    private func keepScreenshot(_ app: XCUIApplication, name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
        let trace = XCTAttachment(string: app.staticTexts["fixture.trust-original"].value as? String ?? app.debugDescription)
        trace.name = name + "-transport-trace"
        trace.lifetime = .keepAlways
        add(trace)
    }
}
