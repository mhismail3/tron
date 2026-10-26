import XCTest

/// Built-app frontend/RPC boundary, not a real-Gateway delivery or migration proof.
/// The socket rejects a wrong digest/missing command ID and exposes actual decisions.
final class TronInlineApprovalBoundaryUITests: XCTestCase {
    @MainActor
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-inline-approval-boundary", "-settings-changes-approvals"]
        app.launch()
        return app
    }

    @MainActor
    func testRequestChipDismissalDecisionAndHistoricalReceipt() {
        let app = launch(); defer { app.terminate() }
        let chip = app.buttons["settings-request-chip-approve"]
        XCTAssertTrue(chip.waitForExistence(timeout: 15), app.debugDescription)
        chip.tap()
        let approve = app.buttons["settings-approval-approve-approve"]
        XCTAssertTrue(approve.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["Done"].exists, "Pending approval has no dismiss/Done decision affordance")
        XCTAssertTrue(app.staticTexts["4 retries → 6 retries"].exists)
        dismissPending(app)
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["fixture.settings-changes-decisions"].label, "decisions:0 approved:0", "Swipe dismissal must retain the request without a decision")
        chip.tap()
        XCTAssertTrue(approve.waitForExistence(timeout: 10))
        approve.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Applied"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["Done"].tap()
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.settings-changes-decisions"], "decisions:1 approved:1"))
        chip.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Applied"].waitForExistence(timeout: 10), "Historical request resolves its complete recorded terminal facts")
        XCTAssertFalse(app.buttons["settings-approval-approve-approve"].exists)
        XCTAssertFalse(app.buttons["Undo"].exists, "The shared outcome is read-only; Changes owns fenced Undo")
        app.buttons["Done"].tap()
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.settings-changes-decisions"], "decisions:1 approved:1"), "Reopening a receipt cannot replay a decision")
        keepScreenshot(app, "1643-request-receipt")
    }

    @MainActor
    func testFailedOutcomeChipIsReadOnlyAndRetainsFullUncertainty() {
        let app = launch(); defer { app.terminate() }
        let chip = app.buttons["settings-outcome-chip-fixture-outcome"]
        XCTAssertTrue(chip.waitForExistence(timeout: 15), app.debugDescription)
        chip.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Failed"].waitForExistence(timeout: 5))
        let diagnostic = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "including the final instruction: verify the existing worktree before creating another one.")).firstMatch
        XCTAssertTrue(diagnostic.exists, "The full original failure remains available to accessibility, not a shortened replacement")
        XCTAssertTrue(app.staticTexts["Value hidden"].exists)
        XCTAssertFalse(app.buttons["settings-approval-approve-settled"].exists)
        XCTAssertFalse(app.buttons["Undo"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.settings-changes-decisions"], "decisions:0 approved:0"))
        keepScreenshot(app, "1643-failed-outcome")
    }

    @MainActor
    private func dismissPending(_ app: XCUIApplication) {
        app.navigationBars.staticTexts["Approve"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
    }
    @MainActor
    private func waitForLabel(_ element: XCUIElement, _ label: String) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)], timeout: 5) == .completed
    }
    @MainActor
    private func keepScreenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name
        attachment.lifetime = .keepAlways; add(attachment)
    }
}
