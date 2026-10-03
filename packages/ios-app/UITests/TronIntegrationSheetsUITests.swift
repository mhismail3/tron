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
    func testXSetupAndAcceptedBeginSurviveBackgroundThroughRealSettingsParents() {
        continueAfterFailure = false
        let app = launch(scenario: "parent-oauth-reconnect")
        defer { app.terminate() }
        openXSetupThroughDashboardSettings(app)

        let client = app.textFields.element(boundBy: 0)
        client.tap(); client.typeText("fixture-public-client")
        let callback = app.textFields.element(boundBy: 1)
        callback.tap(); callback.typeText("https://example.test/callback")
        let draftViewID = xSetupStateID(app)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.staticTexts["Set up X"].waitForExistence(timeout: 10), presentationTrace(app))
        XCTAssertTrue(client.value as? String == "fixture-public-client")
        XCTAssertTrue(callback.value as? String == "https://example.test/callback")
        XCTAssertEqual(xSetupStateID(app), draftViewID, presentationTrace(app))

        app.buttons["Authorize X"].tap()
        XCTAssertTrue(oauthCounters(app, contain: "begins:1 uniqueBeginCommands:1 completes:0"), oauthCountersLabel(app))
        XCTAssertTrue(oauthCounters(app, contain: "client=true redirect=true"), presentationTrace(app))
        XCTAssertTrue(app.buttons["Open X consent"].waitForExistence(timeout: 10), presentationTrace(app))
        XCTAssertTrue(oauthCounters(app, contain: "begins:1 uniqueBeginCommands:1 completes:0"), "Consent/code must not be auto-submitted")
        let acceptedViewID = xSetupStateID(app)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["Open X consent"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(client.value as? String, "fixture-public-client")
        XCTAssertEqual(xSetupStateID(app), acceptedViewID, presentationTrace(app))
        XCTAssertTrue(oauthCounters(app, contain: "begins:1 uniqueBeginCommands:1 completes:0"), oauthCountersLabel(app))
        XCTAssertTrue(presentationTrace(app).contains("settings.root.appear"), presentationTrace(app))
        keepScreenshot(app, name: "366-x-oauth-survives-real-settings-parent-background")
    }

    @MainActor
    func testXSetupImmediateAuthorizeAndPendingCatalogReloadThroughRealSettingsParents() {
        continueAfterFailure = false
        let app = launch(scenario: "parent-oauth-pending-reconnect")
        defer { app.terminate() }
        openXSetupThroughDashboardSettings(app)

        let client = app.textFields.element(boundBy: 0)
        client.tap(); client.typeText("fixture-public-client")
        let callback = app.textFields.element(boundBy: 1)
        callback.tap(); callback.typeText("https://example.test/callback")
        let setupViewID = xSetupStateID(app)
        let destination = app.staticTexts["fixture.destination"].label

        // This is the treatment: submit immediately while the callback field is focused.
        app.buttons["Authorize X"].tap()
        XCTAssertTrue(oauthCounters(app, contain: "begins:1 uniqueBeginCommands:1 completes:0"), oauthCountersLabel(app))
        XCTAssertTrue(oauthCounters(app, contain: "client=true redirect=true"), oauthCountersLabel(app))
        XCTAssertTrue(app.staticTexts["Completing setup…"].waitForExistence(timeout: 5), presentationTrace(app))
        XCUIDevice.shared.press(.home)
        app.activate()

        XCTAssertTrue(oauthCounters(app, contain: "revision=2 pending=1 instances=3"), oauthCountersLabel(app))
        XCTAssertTrue(app.buttons["Open X consent"].waitForExistence(timeout: 10), presentationTrace(app))
        XCTAssertEqual(xSetupStateID(app), setupViewID, presentationTrace(app))
        XCTAssertEqual(app.staticTexts["fixture.destination"].label, destination)
        XCTAssertTrue(client.value as? String == "fixture-public-client")
        XCTAssertTrue(callback.value as? String == "https://example.test/callback")
        XCTAssertTrue(oauthCounters(app, contain: "begins:1 uniqueBeginCommands:1 completes:0"), oauthCountersLabel(app))
        XCTAssertTrue(presentationTrace(app).contains("settings.root.appear"), presentationTrace(app))
        XCTAssertTrue(xSetupLogContains(app, "xsetup.begin.admitted"), productionXLogs(app))
        XCTAssertTrue(xSetupLogContains(app, "xsetup.begin.returned"), productionXLogs(app))
        XCTAssertTrue(xSetupLogEventContains(app, event: "xsetup.begin.returned", fact: "returnOrigin=begin-executor-return"), productionXLogs(app))
        XCTAssertTrue(xSetupLogContains(app, "xsetup.begin.state-assigned"), productionXLogs(app))
        XCTAssertTrue(xSetupLogContains(app, "xsetup.observer.published"), productionXLogs(app))
    }

    @MainActor
    func testXSetupAcceptedBeginReturnsFromStoredReceiptAfterOriginalReplyIsHeld() {
        continueAfterFailure = false
        let app = launch(scenario: "parent-oauth-receipt-return")
        defer { app.terminate() }
        openXSetupThroughDashboardSettings(app)
        enterXClientAndCallback(app)
        app.buttons["Authorize X"].tap()
        XCTAssertTrue(app.staticTexts["Completing setup…"].waitForExistence(timeout: 5), presentationTrace(app))
        XCTAssertTrue(oauthCounters(app, contain: "begins:1 uniqueBeginCommands:1"), oauthCountersLabel(app))

        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(app.buttons["Open X consent"].waitForExistence(timeout: 20), presentationTrace(app))
        XCTAssertTrue(oauthCounters(app, contain: "queries:1 receiptReturns:1 replyReleases:0"), oauthCountersLabel(app))
        XCTAssertTrue(oauthCounters(app, contain: "begins:1 uniqueBeginCommands:1 completes:0"), oauthCountersLabel(app))
        XCTAssertTrue(oauthCounters(app, contain: "mismatches:0"), oauthCountersLabel(app))
        XCTAssertTrue(xSetupLogContains(app, "xsetup.begin.admitted"), productionXLogs(app))
        XCTAssertTrue(xSetupLogContains(app, "xsetup.begin.returned"), productionXLogs(app))
        XCTAssertTrue(xSetupLogEventContains(app, event: "xsetup.begin.returned", fact: "returnOrigin=begin-executor-return"), productionXLogs(app))
        XCTAssertTrue(xSetupLogContains(app, "xsetup.begin.state-assigned"), productionXLogs(app))
        XCTAssertTrue(xSetupLogContains(app, "xsetup.observer.published"), productionXLogs(app))
        let captured = productionXLogs(app)
        XCTAssertFalse(captured.contains("fixture-public-client"), captured)
        XCTAssertFalse(captured.contains("https://example.test/callback"), captured)
        XCTAssertFalse(captured.contains("authorizationUrl"), captured)
        keepScreenshot(app, name: "366-x-begin-typed-result-from-status-receipt")
    }

    @MainActor
    func testXSetupImmediateAuthorizeSubmitsCommittedPaidBudget() {
        continueAfterFailure = false
        let app = launch(scenario: "parent-oauth-policy")
        defer { app.terminate() }
        openXSetupThroughDashboardSettings(app)

        let client = app.textFields.element(boundBy: 0)
        client.tap(); client.typeText("fixture-public-client")
        let callback = app.textFields.element(boundBy: 1)
        callback.tap(); callback.typeText("https://example.test/callback")
        let paidAccess = app.switches["Paid access approved"]
        XCTAssertTrue(paidAccess.waitForExistence(timeout: 5), presentationTrace(app))
        paidAccess.tap()
        app.swipeUp()
        let budget = app.textFields["Paid budget"]
        XCTAssertTrue(budget.waitForExistence(timeout: 5), presentationTrace(app))
        budget.tap(); budget.typeText("725")
        XCTAssertEqual(budget.value as? String, "7250")
        // The initial zero is retained by the field; the visible valid value is 7250.
        // Focus loss and the accepted begin happen in the same native interaction.
        app.buttons["Authorize X"].tap()

        XCTAssertTrue(oauthCounters(app, contain: "begins:1 uniqueBeginCommands:1 completes:0"), oauthCountersLabel(app))
        XCTAssertTrue(oauthCounters(app, contain: "client=true redirect=true"), oauthCountersLabel(app))
        XCTAssertTrue(oauthCounters(app, contain: "policy:enabled=true paid=true budget=7250 recurring=false"), oauthCountersLabel(app))
        XCTAssertTrue(app.buttons["Open X consent"].waitForExistence(timeout: 10), presentationTrace(app))
        XCTAssertTrue(oauthCounters(app, contain: "begins:1 uniqueBeginCommands:1 completes:0"), oauthCountersLabel(app))
    }

    @MainActor
    func testXSetupRevokesOnlyAfterActualGatewayDestinationReplacement() {
        continueAfterFailure = false
        let app = launch(scenario: "parent-oauth-replace")
        defer { app.terminate() }
        openXSetupThroughDashboardSettings(app)
        app.textFields.element(boundBy: 0).tap(); app.textFields.element(boundBy: 0).typeText("fixture-public-client")
        app.textFields.element(boundBy: 1).tap(); app.textFields.element(boundBy: 1).typeText("https://example.test/callback")
        app.buttons["Authorize X"].tap()
        XCTAssertTrue(app.buttons["Open X consent"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(oauthCounters(app, contain: "begins:1 uniqueBeginCommands:1 completes:0"), app.debugDescription)

        XCUIDevice.shared.press(.home)
        app.activate()
        let destination = app.staticTexts["fixture.destination"]
        let replacement = NSPredicate(format: "label CONTAINS %@", "destination=replacement-integration-fixture:")
        expectation(for: replacement, evaluatedWith: destination)
        waitForExpectations(timeout: 15)
        XCTAssertFalse(app.staticTexts["Set up X"].exists, "A replacement Gateway must not inherit the old PKCE form")
        let trace = presentationTrace(app)
        XCTAssertTrue(trace.contains("integrations.destination old=integration-fixture:g0 new=integration-fixture:g1 setupOpen=true"), trace)
        XCTAssertTrue(trace.contains("integrations.destination old=integration-fixture:g1 new=replacement-integration-fixture:g1 setupOpen=false"), trace)
        XCTAssertTrue(trace.contains("xsetup.disappear dest=integration-fixture:g1"), trace)
        XCTAssertTrue(oauthCounters(app, contain: "begins:1 uniqueBeginCommands:1 completes:0"), app.debugDescription)
        XCTAssertTrue(xSetupLogContains(app, "xsetup.destination-retired"), productionXLogs(app))
        XCTAssertTrue(xSetupLogContains(app, "reason=destination-changed"), productionXLogs(app))
        keepScreenshot(app, name: "366-x-form-revoked-on-original-gateway-replacement")
    }

    @MainActor
    private func openXSetupThroughDashboardSettings(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["dashboard.menu"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["dashboard.menu"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["Settings"].tap()
        let connectedServices = app.buttons["Connected Services"]
        XCTAssertTrue(connectedServices.waitForExistence(timeout: 10), app.debugDescription)
        connectedServices.tap()
        XCTAssertTrue(app.buttons["Details for X"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["Details for X"].tap()
        app.buttons["Add another account for X"].tap()
        XCTAssertTrue(app.staticTexts["Set up X"].waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    private func presentationTrace(_ app: XCUIApplication) -> String {
        app.staticTexts["fixture.integration-presentation-trace"].label
    }

    @MainActor
    private func xSetupStateID(_ app: XCUIApplication) -> String {
        let events = presentationTrace(app).split(separator: "|").map(String.init)
        return events.last(where: { $0.hasPrefix("xsetup.appear") })?
            .components(separatedBy: " view=").last ?? ""
    }

    @MainActor
    func testXSetupExplicitCommitSubmitsSamePaidBudgetOnce() {
        continueAfterFailure = false
        let app = launch(scenario: "parent-oauth-policy")
        defer { app.terminate() }
        openXSetupThroughDashboardSettings(app)
        enterXClientAndCallback(app)
        let budget = enableAndEditXBudget(app, digits: "7250")
        // Focus another text field before submitting; this is the explicit-commit control.
        app.textFields.element(boundBy: 1).tap()
        XCTAssertEqual(budget.value as? String, "7250")
        app.buttons["Authorize X"].tap()

        XCTAssertTrue(oauthCounters(app, contain: "begins:1 uniqueBeginCommands:1 completes:0"), oauthCountersLabel(app))
        XCTAssertTrue(oauthCounters(app, contain: "policy:enabled=true paid=true budget=7250 recurring=false"), oauthCountersLabel(app))
        XCTAssertTrue(app.buttons["Open X consent"].waitForExistence(timeout: 10), oauthCountersLabel(app))
    }

    @MainActor
    func testXSetupEmptyStagedBudgetBlocksBeginAndRetainsInput() {
        continueAfterFailure = false
        let app = launch(scenario: "parent-oauth-policy")
        defer { app.terminate() }
        openXSetupThroughDashboardSettings(app)
        enterXClientAndCallback(app)
        let budget = enableAndEditXBudget(app, digits: "")
        XCTAssertEqual(budget.value as? String, "Paid budget", "The label is the field's empty-string placeholder.")
        app.buttons["Authorize X"].tap()

        XCTAssertTrue(app.staticTexts["Enter a whole number without separators."].waitForExistence(timeout: 5), oauthCountersLabel(app))
        XCTAssertTrue(app.textFields["Paid budget"].exists)
        XCTAssertEqual(budget.value as? String, "Paid budget", "Rejected input remains empty for correction.")
        XCTAssertTrue(oauthCounters(app, contain: "begins:0 uniqueBeginCommands:0 completes:0"), oauthCountersLabel(app))
    }

    @MainActor
    func testConnectionDetailsSaveUsesStagedBudgetAsOnlyChange() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        app.buttons["Details for X"].tap()
        let budget = app.textFields["Paid budget"]
        XCTAssertTrue(budget.waitForExistence(timeout: 5))
        replaceNumeric(budget, with: "7500")
        XCTAssertEqual(budget.value as? String, "7500")
        app.buttons["Save"].tap()

        XCTAssertTrue(oauthCounters(app, contain: "policyUpdates:1 policyBudget=7500"), oauthCountersLabel(app))
        XCTAssertFalse(app.buttons["Save"].exists)
    }

    @MainActor
    func testConnectionDetailsSaveMergesStagedBudgetWithPolicyToggle() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Details for X"].waitForExistence(timeout: 10))
        app.buttons["Details for X"].tap()
        app.switches["Enabled"].tap()
        let budget = app.textFields["Paid budget"]
        XCTAssertTrue(budget.waitForExistence(timeout: 5))
        replaceNumeric(budget, with: "6400")
        app.buttons["Save"].tap()

        XCTAssertTrue(oauthCounters(app, contain: "policyUpdates:1 policyBudget=6400 policyEnabled=false"), oauthCountersLabel(app))
    }

    @MainActor
    func testConnectionDetailsNoOpSaveDoesNotMutate() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        app.buttons["Details for X"].tap()
        XCTAssertTrue(app.textFields["Paid budget"].waitForExistence(timeout: 5))
        app.buttons["Save"].tap()
        XCTAssertTrue(oauthCounters(app, contain: "policyUpdates:0"), oauthCountersLabel(app))
        XCTAssertFalse(app.buttons["Save"].exists)
    }

    @MainActor
    func testNonXSetupUsesStagedPolicyForAcceptedCompletion() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        app.buttons.matching(identifier: "Details for Raindrop").firstMatch.tap()
        app.buttons["Add another account for Raindrop"].tap()
        XCTAssertTrue(app.staticTexts["Set up Raindrop"].waitForExistence(timeout: 5))
        let account = app.textFields.element(boundBy: 1)
        account.tap(); account.typeText("fixture-account")
        let credential = app.textFields.element(boundBy: 3)
        credential.tap(); credential.typeText("fixture-credential-ref")
        let paidAccess = app.switches["Paid access approved"]
        paidAccess.tap()
        app.swipeUp()
        let budget = app.textFields["Paid budget"]
        XCTAssertTrue(budget.waitForExistence(timeout: 5))
        replaceNumeric(budget, with: "6400")
        XCTAssertEqual(budget.value as? String, "6400")
        app.buttons["Save"].tap()

        XCTAssertTrue(oauthCounters(app, contain: "setupBegins:1 setupCompletes:1 setupBudget=6400"), oauthCountersLabel(app))
    }

    @MainActor
    private func enterXClientAndCallback(_ app: XCUIApplication) {
        let client = app.textFields.element(boundBy: 0)
        client.tap(); client.typeText("fixture-public-client")
        let callback = app.textFields.element(boundBy: 1)
        callback.tap(); callback.typeText("https://example.test/callback")
    }

    @MainActor
    private func enableAndEditXBudget(_ app: XCUIApplication, digits: String) -> XCUIElement {
        let paidAccess = app.switches["Paid access approved"]
        XCTAssertTrue(paidAccess.waitForExistence(timeout: 5), oauthCountersLabel(app))
        paidAccess.tap()
        app.swipeUp()
        let budget = app.textFields["Paid budget"]
        XCTAssertTrue(budget.waitForExistence(timeout: 5), oauthCountersLabel(app))
        replaceNumeric(budget, with: digits)
        return budget
    }

    @MainActor
    private func replaceNumeric(_ field: XCUIElement, with text: String) {
        field.tap()
        field.press(forDuration: 0.8)
        let selectAll = XCUIApplication().menuItems["Select All"]
        if selectAll.waitForExistence(timeout: 1) {
            selectAll.tap()
        } else {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
        let deleteCount = text.isEmpty ? 1 : 80
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: deleteCount))
        if !text.isEmpty { field.typeText(text) }
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
    func testMissingOAuthReceiptOffersOnlyOriginalStatusQueries() {
        continueAfterFailure = false
        let app = launch(scenario: "oauth-missing")
        defer { app.terminate() }
        openXSetup(app)
        app.buttons["Authorize X"].tap()
        XCTAssertTrue(oauthCounters(app, contain: "begins:1"))
        XCUIDevice.shared.press(.home); app.activate()
        let check = app.buttons["Check setup status"]
        XCTAssertTrue(check.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.buttons["Authorize X"].exists)
        XCTAssertEqual(app.textFields.element(boundBy: 0).value as? String, "fixture-public-client")
        check.tap()
        XCTAssertTrue(oauthCounters(app, contain: "queries:2"))
        XCTAssertTrue(oauthCounters(app, contain: "begins:1 uniqueBeginCommands:1 completes:0"))
        XCTAssertTrue(oauthCounters(app, contain: "mismatches:0"))
        XCTAssertTrue(check.exists)
        keepScreenshot(app, name: "348-oauth-missing-original-status-only")
    }

    @MainActor
    func testAcceptedOAuthCompleteSettlesOriginalReceiptAfterBackground() {
        continueAfterFailure = false
        let app = launch(scenario: "parent-oauth-complete-delayed")
        defer { app.terminate() }
        openXSetupThroughDashboardSettings(app)
        enterXClientAndCallback(app)
        app.buttons["Authorize X"].tap()
        XCTAssertTrue(app.buttons["Open X consent"].waitForExistence(timeout: 10))
        let code = app.textFields.element(boundBy: 3)
        code.tap(); code.typeText("fixture-one-time-code")
        app.buttons["Complete setup"].tap()
        XCTAssertTrue(oauthCounters(app, contain: "completes:1"))
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(app.staticTexts["Connected test X"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.staticTexts["Set up X"].exists)
        XCTAssertTrue(oauthCounters(app, contain: "begins:1 uniqueBeginCommands:1 completes:1"))
        XCTAssertTrue(oauthCounters(app, contain: "mismatches:0"))
        XCTAssertTrue(xSetupLogContains(app, "xsetup.explicit-finish"), productionXLogs(app))
        XCTAssertTrue(xSetupLogContains(app, "xsetup.binding.set-false"), productionXLogs(app))
        XCTAssertFalse(productionXLogs(app).contains("fixture-one-time-code"), productionXLogs(app))
        XCTAssertFalse(productionXLogs(app).contains("https://example.test/callback"), productionXLogs(app))
        keepScreenshot(app, name: "348-oauth-complete-original-receipt")
    }

    @MainActor
    func testExpiredOAuthCompleteKeepsInputsAndOriginalRefusal() {
        continueAfterFailure = false
        let app = launch(scenario: "oauth-expired")
        defer { app.terminate() }
        openXSetup(app)
        app.buttons["Authorize X"].tap()
        XCTAssertTrue(app.buttons["Open X consent"].waitForExistence(timeout: 10))
        let code = app.textFields.element(boundBy: 3)
        code.tap(); code.typeText("fixture-one-time-code")
        app.buttons["Complete setup"].tap()
        XCTAssertTrue(oauthCounters(app, contain: "completes:1"))
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(app.staticTexts["X OAuth setup expired; start authorization again"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(code.value as? String, "fixture-one-time-code")
        XCTAssertTrue(oauthCounters(app, contain: "begins:1 uniqueBeginCommands:1 completes:1"))
        XCTAssertFalse(app.staticTexts["Connected test X"].exists)
        keepScreenshot(app, name: "348-oauth-expired-no-redispatch")
    }

    @MainActor
    private func openXSetup(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["Details for X"].waitForExistence(timeout: 10))
        app.buttons["Details for X"].tap(); app.buttons["Add another account for X"].tap()
        XCTAssertTrue(app.staticTexts["Set up X"].waitForExistence(timeout: 5))
        app.textFields.element(boundBy: 0).tap(); app.textFields.element(boundBy: 0).typeText("fixture-public-client")
        app.textFields.element(boundBy: 1).tap(); app.textFields.element(boundBy: 1).typeText("https://example.test/callback")
    }

    @MainActor
    private func productionXLogs(_ app: XCUIApplication) -> String {
        app.staticTexts["fixture.production-x-logs"].label
    }

    @MainActor
    private func xSetupLogContains(_ app: XCUIApplication, _ expected: String) -> Bool {
        let condition = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", expected),
            object: app.staticTexts["fixture.production-x-logs"]
        )
        return XCTWaiter.wait(for: [condition], timeout: 10) == .completed
    }

    @MainActor
    private func xSetupLogEventContains(_ app: XCUIApplication, event: String, fact: String) -> Bool {
        productionXLogs(app).split(separator: "|").contains { $0.contains(event) && $0.contains(fact) }
    }

    @MainActor
    private func oauthCountersLabel(_ app: XCUIApplication) -> String {
        app.staticTexts["fixture.oauth-counters"].label
    }

    @MainActor
    private func oauthCounters(_ app: XCUIApplication, contain expected: String) -> Bool {
        let condition = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", expected), object: app.staticTexts["fixture.oauth-counters"])
        return XCTWaiter.wait(for: [condition], timeout: 10) == .completed
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
