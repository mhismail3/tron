import XCTest

/// The one approval chip and sheet (#2050) over the production managed-sheet path
/// and HostedSettingsRendererSocket's `settings.approvals`/`settings.decide`/`settings.history`.
/// Gateway delivery is proved by the Gateway E2E suites and the real-Gateway journey;
/// these are hosted frontend boundary journeys and labelled visual captures.
final class TronSettingsApprovalFormUITests: XCTestCase {
    @MainActor
    private func launchPreview(dark: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-inline-approval-boundary", "-approval-requests-preview",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if dark { app.launchArguments.append("-settings-renderer-dark") }
        app.launch()
        return app
    }

    @MainActor
    private func chip(_ app: XCUIApplication, _ requestID: String) -> XCUIElement {
        app.buttons["settings-approval-chip-\(requestID)"]
    }

    @MainActor
    private func keep(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func dismissSheet(_ app: XCUIApplication, title: String) {
        app.navigationBars.staticTexts[title].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
    }

    /// Large detent, so a capture shows the whole request rather than its first rows.
    @MainActor
    private func expand(_ app: XCUIApplication, title: String) {
        app.navigationBars.staticTexts[title].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)))
    }

    @MainActor
    private func waitForLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 5) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: element)], timeout: timeout) == .completed
    }

    /// Visual review captures in both appearances: the chat's chips, the sheet a
    /// waiting request opens, the sheet a returned-pending request opens, Changes'
    /// Waiting for you and the decided (Applied) state. Fixture data, labelled.
    @MainActor
    func testCaptureApprovalRequestSurfacesInLightAndDark() {
        continueAfterFailure = false
        for (mode, dark) in [("light", false), ("dark", true)] {
            let app = launchPreview(dark: dark)
            let profile = chip(app, "profile-wait"), retries = chip(app, "settings-pending")
            XCTAssertTrue(profile.waitForExistence(timeout: 15), app.debugDescription)
            XCTAssertTrue(waitForLabel(profile, containing: "Waiting for you"), profile.label)
            keep(app, "2050-chat-chips-\(mode)")
            profile.tap()
            XCTAssertTrue(app.staticTexts["Prefers short morning check-ins over long evening calls."].waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(app.staticTexts["Unsorted › Review → Routines & wellbeing › Check ins"].exists)
            XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "{\"id\"")).count, 0, "Exact identity stays behind the technical disclosure")
            expand(app, title: "Approve")
            keep(app, "2050-sheet-waiting-profile-\(mode)")
            app.buttons["Technical details"].tap()
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Exact identity")).firstMatch.waitForExistence(timeout: 5))
            keep(app, "2050-sheet-exact-identity-\(mode)")
            app.buttons["Back"].tap()
            dismissSheet(app, title: "Approve")
            XCTAssertTrue(retries.waitForExistence(timeout: 5))
            retries.tap()
            XCTAssertTrue(app.staticTexts["3 retries → 5 retries"].waitForExistence(timeout: 10), app.debugDescription)
            expand(app, title: "Approve")
            keep(app, "2050-sheet-pending-settings-\(mode)")
            dismissSheet(app, title: "Approve")
            app.buttons["fixture-open-changes"].tap()
            XCTAssertTrue(app.buttons["settings-changes-pending-profile-wait"].waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(app.buttons["settings-changes-pending-settings-pending"].exists)
            keep(app, "2050-changes-waiting-\(mode)")
            app.buttons["settings-changes-pending-profile-wait"].tap()
            let approve = app.buttons["settings-approval-approve-profile-wait"]
            XCTAssertTrue(approve.waitForExistence(timeout: 10), app.debugDescription)
            approve.tap()
            XCTAssertTrue(app.navigationBars.staticTexts["Applied"].waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(app.staticTexts["Keeps a paper notebook for travel plans."].exists, "The decided state keeps the same rows")
            expand(app, title: "Applied")
            keep(app, "2050-applied-\(mode)")
            app.buttons["Done"].tap()
            XCTAssertTrue(app.buttons["settings-changes-pending-profile-wait"].waitForNonExistence(timeout: 5),
                          "A decided request leaves Waiting for you at once")
            keep(app, "2050-changes-after-decision-\(mode)")
            app.terminate()
        }
    }

    /// A decision in Changes settles the chat's chip; dismissing the chat sheet
    /// never decides, and its chip reopens the same request.
    @MainActor
    func testDismissedRequestWaitsBehindItsChipAndChangesDecisionSettlesIt() {
        continueAfterFailure = false
        let app = launchPreview(dark: false); defer { app.terminate() }
        let decisions = app.staticTexts["fixture.settings-changes-decisions"]
        let retries = chip(app, "settings-pending")
        XCTAssertTrue(retries.waitForExistence(timeout: 15), app.debugDescription)
        retries.tap()
        XCTAssertTrue(app.buttons["settings-approval-approve-settings-pending"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["Done"].exists, "A waiting request has no Done: only Approve or Decline decides")
        dismissSheet(app, title: "Approve")
        XCTAssertTrue(waitForLabel(retries, containing: "Waiting for you"), retries.label)
        XCTAssertTrue(waitForLabel(decisions, containing: "decisions:0"), "Dismissal sends no decision")
        retries.tap()
        XCTAssertTrue(app.buttons["settings-approval-decline-settings-pending"].waitForExistence(timeout: 10))
        dismissSheet(app, title: "Approve")
        app.buttons["fixture-open-changes"].tap()
        let row = app.buttons["settings-changes-pending-settings-pending"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        row.tap()
        let decline = app.buttons["settings-approval-decline-settings-pending"]
        XCTAssertTrue(decline.waitForExistence(timeout: 10), app.debugDescription)
        decline.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Declined"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["Done"].tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "The declined request leaves Waiting for you at once")
        XCTAssertTrue(waitForLabel(decisions, containing: "decisions:1 approved:0"))
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(waitForLabel(retries, containing: "Declined"), "The chat's chip shows the decision made in Changes: \(retries.label)")
        retries.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Declined"].waitForExistence(timeout: 10), "The chip reopens the decided state, not a decision")
        XCTAssertFalse(app.buttons["settings-approval-approve-settings-pending"].exists)
    }

    @MainActor
    func testAskUserToolRowReopensAndSubmits() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-ask-user-fixture", "-tron-ask-user-tool-row"]
        app.launch()
        let send = app.buttons["Submit all answers"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), app.debugDescription)
        let window = app.windows.firstMatch
        let title = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: window.frame.midX, dy: send.frame.midY))
        title.press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        let row = app.buttons["ask-user-pending-tool"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Mutation count: 0"].exists)
        row.tap()
        XCTAssertTrue(send.waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["Staging"].tap()
        send.tap()
        XCTAssertTrue(app.staticTexts["extension.respond cancelled=false selected=environment-a other="].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Mutation count: 1"].exists)
        app.terminate()
    }
}
