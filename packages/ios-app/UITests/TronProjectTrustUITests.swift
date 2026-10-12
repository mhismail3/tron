import XCTest

/// Real Project Trust controls against synthetic authority only. The fake
/// Gateway commits and broadcasts before withholding a typed command reply.
final class TronProjectTrustUITests: XCTestCase {
    @MainActor
    func testEarlierTrustReceiptCannotReplaceLaterCanonicalBlock() {
        let app = launch(scenario: "held")
        defer { app.terminate() }
        acceptTrustThenBlock(app)
        app.buttons["fixture.release-trust"].tap()
        XCTAssertTrue(counts(app, contain: "firstReply:1"))
        assertBlockedWithoutLateTrust(app, screenshot: "358-trust-earlier-receipt-after-current-block")
        assertOriginalCommands(app, count: 2)
    }

    @MainActor
    func testEarlierInspectCannotReplaceLaterCanonicalBlock() {
        let app = launch(scenario: "inspect-value-held")
        defer { app.terminate() }
        holdOlderInspectThenBlock(app)
        app.buttons["fixture.release-trust-reads"].tap()
        XCTAssertTrue(counts(app, contain: "releasedReads:2"), app.debugDescription)
        assertBlockedWithoutLateTrust(app, screenshot: "358-trust-earlier-inspect-after-current-block")
        assertOriginalCommands(app, count: 2)
    }

    @MainActor
    func testEarlierInspectErrorCannotPublishAfterLaterCanonicalBlock() {
        let app = launch(scenario: "inspect-error-held")
        defer { app.terminate() }
        holdOlderInspectThenBlock(app)
        app.buttons["fixture.release-trust-reads"].tap()
        XCTAssertTrue(counts(app, contain: "releasedReads:2"), app.debugDescription)
        let staleError = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Earlier trust read failure"),
                                                   object: app.staticTexts["fixture.trust-notices"])
        let observed = XCTWaiter.wait(for: [staleError], timeout: 2)
        keepScreenshot(app, name: "358-trust-earlier-inspect-error-retired")
        XCTAssertEqual(observed, .timedOut, "An earlier trust read cannot publish an error into the newer inspection")
        XCTAssertTrue(app.staticTexts["Resources blocked"].exists)
        assertOriginalCommands(app, count: 2)
    }

    @MainActor
    private func holdOlderInspectThenBlock(_ app: XCUIApplication) {
        app.buttons["Trust Project"].tap()
        // Both the change-event read and accepted command's reconciliation
        // read must be held; no inferred mock callback is being exercised.
        XCTAssertTrue(counts(app, contain: "heldReads:2"), app.debugDescription)
        app.buttons["Do Not Load Project Resources"].tap()
        XCTAssertTrue(positiveCount(app, field: "readsFalse"), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Resources blocked"].waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor
    func testMatchingSingleBlockSettlesWithoutAnotherCommand() {
        let app = launch(scenario: "ordered")
        defer { app.terminate() }
        app.buttons["Do Not Load Project Resources"].tap()
        XCTAssertTrue(app.staticTexts["Resources blocked"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(counts(app, contain: "canonical:false"))
        assertOriginalCommands(app, count: 1)
        keepScreenshot(app, name: "358-trust-matching-single-block")
    }

    @MainActor
    func testOrderedTrustThenBlockShowsBothCanonicalResults() {
        let app = launch(scenario: "ordered")
        defer { app.terminate() }
        app.buttons["Trust Project"].tap()
        XCTAssertTrue(app.staticTexts["Trusted"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(positiveCount(app, field: "readsTrue"))
        app.buttons["Do Not Load Project Resources"].tap()
        XCTAssertTrue(app.staticTexts["Resources blocked"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(positiveCount(app, field: "readsFalse"))
        assertOriginalCommands(app, count: 2)
        keepScreenshot(app, name: "358-trust-ordered-results")
    }

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
    func testOriginalTrustCannotAttachToReplacementMacWithSameCWD() {
        let app = launch(scenario: "held")
        defer { app.terminate() }
        app.buttons["Trust Project"].tap()
        XCTAssertTrue(counts(app, contain: "held:1"))
        XCTAssertTrue(app.staticTexts["Trusted"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["fixture.replace-trust-profile"].tap()
        XCTAssertTrue(positiveCount(app, field: "readsFalse", id: "fixture.trust-replacement"), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Resources blocked"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["fixture.release-trust"].tap()
        assertBlockedWithoutLateTrust(app, screenshot: "358-trust-replacement-mac-colliding-cwd")
        assertOriginalCommands(app, count: 1)
        XCTAssertTrue(counts(app, id: "fixture.trust-replacement", contain: "sets:0 commands:0 repeats:0"))
    }

    /// Permissions › Floors (settings-model.md 5.4): lowering a floor is an approve-tier
    /// change that waits for the maintainer's confirm; raising it applies at once.
    @MainActor
    func testPermissionFloorsLowerNeedsConfirmAndRaiseApplies() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-project-trust-fixture", "-project-trust-scenario", "floors"]
        app.launch()
        defer { app.terminate() }
        let section = app.buttons["settings-section-permissions-expand"]
        XCTAssertTrue(section.waitForExistence(timeout: 15), app.debugDescription)
        section.tap()
        let row = app.descendants(matching: .any)["settings-row-permissions.floor_direction_widen_key_permissions.projectTrust"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(counts(app, contain: "floor:approve previews:0 applies:0"), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Project trust (widen)"].exists && app.staticTexts["Built-in"].exists, app.debugDescription)

        // Lowering: the dry run carries confirm text, and nothing is applied until confirmed.
        choose(app, row: row, option: "Quiet")
        let confirm = app.buttons["Change setting"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(counts(app, contain: "floor:approve previews:1 applies:0"), app.debugDescription)
        keepScreenshot(app, name: "758-permission-floor-lower-confirm")
        // Native confirmation may adapt to a popover with outside dismissal.
        app.staticTexts["permissions"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        XCTAssertTrue(counts(app, contain: "floor:approve previews:1 applies:0"), "Cancelling must not lower the floor")
        choose(app, row: row, option: "Quiet")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(counts(app, contain: "floor:quiet previews:2 applies:1"), app.debugDescription)
        XCTAssertTrue(waitForValue(row.buttons.firstMatch, "Quiet"), app.debugDescription)
        // The override is now the Mac layer's, named by the row's layer badge.
        XCTAssertTrue(app.staticTexts["Mac"].waitForExistence(timeout: 5), app.debugDescription)

        // Raising: the dry run needs no confirm, so the choice applies directly.
        choose(app, row: row, option: "Approve")
        XCTAssertTrue(counts(app, contain: "floor:approve previews:3 applies:2"), app.debugDescription)
        XCTAssertFalse(app.buttons["Change setting"].firstMatch.exists)
        XCTAssertTrue(waitForValue(row.buttons.firstMatch, "Approve"), app.debugDescription)
        keepScreenshot(app, name: "758-permission-floor-raise-applied")
    }

    @MainActor
    private func choose(_ app: XCUIApplication, row: XCUIElement, option: String) {
        let control = row.buttons.firstMatch.buttons.firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 5), app.debugDescription)
        control.tap()
        let slider = app.descendants(matching: .any)["settings-choice-slider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5), app.debugDescription)
        // Tiers are an ordered choice in the real schema, sharing the same
        // drawn rail as thinking. Assert the label, not merely a coordinate.
        slider.coordinate(withNormalizedOffset: CGVector(dx: option == "Quiet" ? 0.1 : 0.9, dy: 0.5)).tap()
        XCTAssertTrue(waitForValue(slider, option), app.debugDescription)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 10, dy: min(app.frame.maxY - 70, slider.frame.maxY + 80))).tap()
        XCTAssertTrue(slider.waitForNonExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    private func waitForValue(_ element: XCUIElement, _ expected: String) -> Bool {
        let condition = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: element)
        return XCTWaiter.wait(for: [condition], timeout: 10) == .completed
    }

    @MainActor
    private func acceptTrustThenBlock(_ app: XCUIApplication) {
        app.buttons["Trust Project"].tap()
        XCTAssertTrue(counts(app, contain: "held:1"), app.debugDescription)
        // The real change event/read may already show Trusted; Block remains
        // available. Holding the reply does not hold canonical application.
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
