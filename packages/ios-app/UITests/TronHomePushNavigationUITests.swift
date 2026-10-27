import XCTest

/// A push tapped as the scene returns to the foreground (#1684, #1686). With Home
/// presented, the tap arrives while the mounted Home chat is restoring its open on
/// the replacement connection — the device journey that showed "The conversation
/// changed while opening".
final class TronHomePushNavigationUITests: XCTestCase {
    private enum Presented { case home, dashboard, ordinaryChat }

    /// A push for Home's own chapter keeps the Home chat: it settles without an
    /// error and still sends through `home.prompt`.
    @MainActor
    func testPushTapForPresentedHomeChapterKeepsHomeOpen() {
        continueAfterFailure = false
        let app = launchThenTapPushOnForeground(presenting: .home)
        defer { app.terminate() }
        assertSettledWithoutOpenFailure(app)
        assertHomeSendsThroughHomePrompt(app)
        keep("1684-home-push-tap-kept-home")
    }

    /// A push for Home's chapter tapped from the dashboard opens Home itself, not
    /// the chapter as an ordinary chat (#1686).
    @MainActor
    func testPushTapForHomeChapterFromDashboardOpensHome() {
        continueAfterFailure = false
        let app = launchThenTapPushOnForeground(presenting: .dashboard)
        defer { app.terminate() }
        assertSettledWithoutOpenFailure(app)
        assertHomeSendsThroughHomePrompt(app)
        keep("1686-home-push-tap-from-dashboard-opened-home")
    }

    /// A push for Home's chapter tapped over another chat replaces it with Home
    /// itself, not the chapter as an ordinary chat (#1686).
    @MainActor
    func testPushTapForHomeChapterOverOtherChatOpensHome() {
        continueAfterFailure = false
        let app = launchThenTapPushOnForeground(presenting: .ordinaryChat)
        defer { app.terminate() }
        assertSettledWithoutOpenFailure(app)
        assertHomeSendsThroughHomePrompt(app)
        keep("1686-home-push-tap-over-chat-opened-home")
    }

    /// A push for another chat replaces Home only after Home's chat retires, so the
    /// restoring Home open cannot take the target's presentation authority.
    @MainActor
    func testPushTapForOtherChatReplacesRestoringHome() {
        continueAfterFailure = false
        let app = launchThenTapPushOnForeground(presenting: .home, ["-home-push-ordinary"])
        defer { app.terminate() }
        assertSettledWithoutOpenFailure(app)
        XCTAssertTrue(waitFor(app.staticTexts["fixture.home-opened-session"], "label == 'opened-session:ordinary-session'"),
                      app.debugDescription)
        XCTAssertTrue(waitFor(app.buttons["session-context-button"], "label CONTAINS 'Manage Session'"), app.debugDescription)
        XCTAssertFalse(app.staticTexts["Conversation unavailable"].waitForExistence(timeout: 3), app.debugDescription)
        keep("1684-home-push-tap-opened-other-chat")
    }

    /// #2050: tapping an approval push opens the requesting chat with its waiting
    /// request in the shared approval sheet. The tap decides nothing; Approve does.
    @MainActor
    func testApprovalPushTapOpensTheRequestInItsChat() {
        continueAfterFailure = false
        let app = launchThenTapPushOnForeground(presenting: .dashboard, ["-home-settings-approvals", "-home-push-approval"])
        defer { app.terminate() }
        assertSettledWithoutOpenFailure(app)
        let approve = app.buttons["settings-approval-approve-settings-request-approve"]
        XCTAssertTrue(approve.waitForExistence(timeout: 15), "The approval push did not open its request: \(app.debugDescription)")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Not set → Trusted")).firstMatch.exists, app.debugDescription)
        XCTAssertFalse(app.buttons["settings-approval-approve-settings-request-chat"].exists, "Another chat's request does not open from this push")
        XCTAssertTrue(waitFor(app.staticTexts["fixture.settings-decisions"], "label == 'settings-decisions:none'"), "The tap alone decided")
        keep("2050-approval-push-opened-sheet")
        approve.tap()
        XCTAssertTrue(waitFor(app.staticTexts["fixture.settings-decisions"], "label CONTAINS 'approved:settings-request-approve'"), app.debugDescription)
    }

    @MainActor
    private func launchThenTapPushOnForeground(presenting presented: Presented, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-dashboard-workers",
                               "-dashboard-view-home", "-home-push-tap-on-foreground"] + extra
        app.launch()
        let homeButton = app.buttons["dashboard.menu"]
        XCTAssertTrue(homeButton.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(waitFor(homeButton, "value == 'Ready'"), app.debugDescription)
        switch presented {
        case .home:
            homeButton.tap()
            XCTAssertTrue(app.textViews["Message input"].waitForExistence(timeout: 15), app.debugDescription)
            XCTAssertTrue(waitFor(app.buttons["session-context-button"], "label CONTAINS 'Manage Home'"), app.debugDescription)
        case .ordinaryChat:
            let ordinary = app.buttons["session-row-home-shell-fixture:ordinary-session"]
            XCTAssertTrue(ordinary.waitForExistence(timeout: 10), app.debugDescription)
            ordinary.tap()
            XCTAssertTrue(app.textViews["Message input"].waitForExistence(timeout: 15), app.debugDescription)
            XCTAssertTrue(waitFor(app.buttons["session-context-button"], "label CONTAINS 'Manage Session'"), app.debugDescription)
        case .dashboard:
            XCTAssertFalse(app.textViews["Message input"].exists, app.debugDescription)
        }
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        return app
    }

    /// The tap is consumed and the chat settles; a benign open never reports the
    /// conversation as changed.
    @MainActor
    private func assertSettledWithoutOpenFailure(_ app: XCUIApplication) {
        let push = app.staticTexts["fixture.home-push"]
        XCTAssertTrue(waitFor(push, "label BEGINSWITH 'push:consumed'", timeout: 15),
                      "The push was never consumed after foreground restore: \(push.label)")
        XCTAssertFalse(app.staticTexts["Conversation unavailable"].waitForExistence(timeout: 8),
                       "Push open failed: \(app.debugDescription)")
        XCTAssertTrue(app.textViews["Message input"].waitForExistence(timeout: 10), app.debugDescription)
    }

    /// The presented chat is Home: it manages Home and sends through `home.prompt`.
    @MainActor
    private func assertHomeSendsThroughHomePrompt(_ app: XCUIApplication) {
        XCTAssertTrue(waitFor(app.buttons["session-context-button"], "label CONTAINS 'Manage Home'"),
                      "The push did not open Home: \(app.buttons["session-context-button"].label)")
        let composer = app.textViews["Message input"]
        composer.tap(); composer.typeText("After the push")
        let send = app.buttons["Send message"]
        XCTAssertTrue(waitFor(send, "enabled == true"), app.debugDescription)
        send.tap()
        XCTAssertTrue(waitFor(app.staticTexts["fixture.home-prompt-route"], "label == 'prompt-route:home.prompt'"),
                      "The push opened Home's chapter as an ordinary chat: \(app.staticTexts["fixture.home-prompt-route"].label)")
    }

    private func waitFor(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 10) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)],
                       timeout: timeout) == .completed
    }

    @MainActor private func keep(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
