import XCTest

extension RealGatewayPairAndChatUITests {
    /// #2050 at the real Gateway: an agent's approval request appears in the chat
    /// that asked, in both modes, and a decision from either surface settles both.
    ///
    /// Failure modes, written before the code:
    /// 1. A waiting request shows nothing in its chat (or only an answerable form),
    ///    so the maintainer must find it in Changes.
    /// 2. Dismissing the sheet loses the request, or decides it.
    /// 3. A request returned pending leaves no chip in the chat.
    /// 4. A decision in Changes leaves the chat's chip, or Changes' own row, waiting.
    /// The fixture provider asks through the real `settings` tool (scripts/ios-gateway-e2e-fixture.sh).
    @MainActor
    func testAgentApprovalRequestsAppearInTheirChatAndSettleEverywhere() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let app = launchApp()
        defer { app.terminate() }
        open(fixture.invitationLink())
        completeFirstRunSetup(app, inWorkspace: fixture.workspace)
        XCTAssertTrue(waitForHittable(app.buttons["dashboard.menu"], timeout: 90), app.debugDescription)
        createSession(app, inWorkspace: fixture.workspace)
        let chips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings-approval-chip-"))

        // 1. The waiting request presents itself in this chat, like a question.
        send(app, "APPROVAL-JOURNEY: ask and wait")
        let approveTitle = app.navigationBars.staticTexts["Approve"]
        XCTAssertTrue(approveTitle.waitForExistence(timeout: 90), "the waiting request never presented in its chat: \(app.debugDescription)")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Fixture approval that waits in this chat")).firstMatch.exists,
                      "the sheet must show the request's own reason: \(app.debugDescription)")
        keepScreenshot(app, name: "2050-real-waiting-sheet")
        // 2. Dismissal keeps it waiting behind its chip, which reopens the same sheet.
        approveTitle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        let waiting = chips.matching(NSPredicate(format: "label CONTAINS %@", "Waiting for you")).firstMatch
        XCTAssertTrue(waitForHittable(waiting, timeout: 30), "the dismissed request left no chip: \(app.debugDescription)")
        keepScreenshot(app, name: "2050-real-waiting-chip")
        waiting.tap()
        let approve = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings-approval-approve-")).firstMatch
        XCTAssertTrue(approve.waitForExistence(timeout: 30), app.debugDescription)
        approve.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Applied"].waitForExistence(timeout: 60), app.debugDescription)
        keepScreenshot(app, name: "2050-real-applied")
        dismissTopSheet(app)
        let heard = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Approval journey heard: approved")).firstMatch
        XCTAssertTrue(heard.waitForExistence(timeout: 90), "the waiting tool call never received the decision: \(app.debugDescription)")

        // 3. A request returned pending leaves the turn and shows its chip.
        send(app, "APPROVAL-JOURNEY: ask without waiting")
        let returned = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Approval journey heard: pending")).firstMatch
        XCTAssertTrue(returned.waitForExistence(timeout: 90), "the pending request held its turn: \(app.debugDescription)")
        XCTAssertFalse(approveTitle.exists, "a request returned pending does not present itself")
        let pendingChip = chips.matching(NSPredicate(format: "label CONTAINS %@", "Waiting for you")).firstMatch
        XCTAssertTrue(waitForHittable(pendingChip, timeout: 30), app.debugDescription)
        let chipID = pendingChip.identifier
        keepScreenshot(app, name: "2050-real-pending-chip")

        // 4. Changes lists it under Waiting for you; deciding there settles the chat's chip.
        let gear = app.navigationBars.buttons["Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 30), app.debugDescription)
        gear.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Global Settings"].waitForExistence(timeout: 30), app.debugDescription)
        for _ in 0..<40 where !app.buttons["Changes"].isHittable { app.swipeDown() }
        app.buttons["Changes"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings-changes-pending-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 60), "Changes has no Waiting for you row: \(app.debugDescription)")
        keepScreenshot(app, name: "2050-real-changes-waiting")
        row.tap()
        let decline = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings-approval-decline-")).firstMatch
        XCTAssertTrue(decline.waitForExistence(timeout: 30), app.debugDescription)
        decline.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Declined"].waitForExistence(timeout: 60), app.debugDescription)
        dismissTopSheet(app)
        XCTAssertTrue(waitUntil(timeout: 15) { !row.exists }, "the declined request stayed under Waiting for you: \(app.debugDescription)")
        let pendingHistory = app.staticTexts.matching(NSPredicate(format: "label == %@", "Pending"))
        XCTAssertEqual(pendingHistory.count, 0, "settled requests leave no Pending history row: \(app.debugDescription)")
        keepScreenshot(app, name: "2050-real-changes-after-decision")
        dismissTopSheet(app) // Changes
        dismissTopSheet(app) // Settings
        let settled = app.buttons[chipID]
        XCTAssertTrue(waitUntil(timeout: 30) { settled.label.contains("Declined") }, "the chat's chip did not follow the Changes decision: \(settled.label)")
        keepScreenshot(app, name: "2050-real-chip-after-changes-decision")
    }

    @MainActor
    private func send(_ app: XCUIApplication, _ text: String) {
        let composer = app.textViews["Message input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 60), app.debugDescription)
        composer.tap()
        composer.typeText(text)
        let send = app.buttons["Send message"]
        XCTAssertTrue(waitForEnabled(send, timeout: 60), app.debugDescription)
        send.tap()
    }
}
