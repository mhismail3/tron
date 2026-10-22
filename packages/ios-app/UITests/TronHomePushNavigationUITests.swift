import XCTest

/// A push tapped while Home is the presented chat (#1684). The tap arrives as the
/// scene returns to the foreground, while the mounted Home chat is restoring its
/// open on the replacement connection — the device journey that showed "The
/// conversation changed while opening".
final class TronHomePushNavigationUITests: XCTestCase {
    /// A push for Home's own chapter keeps the Home chat: it settles without an
    /// error and still sends through `home.prompt`.
    @MainActor
    func testPushTapForPresentedHomeChapterKeepsHomeOpen() {
        continueAfterFailure = false
        let app = launchHomeThenTapPushOnForeground()
        defer { app.terminate() }
        assertSettledWithoutOpenFailure(app)
        XCTAssertTrue(waitFor(app.buttons["session-context-button"], "label CONTAINS 'Manage Home'"), app.debugDescription)
        let composer = app.textViews["Message input"]
        composer.tap(); composer.typeText("After the push")
        let send = app.buttons["Send message"]
        XCTAssertTrue(waitFor(send, "enabled == true"), app.debugDescription)
        send.tap()
        XCTAssertTrue(waitFor(app.staticTexts["fixture.home-prompt-route"], "label == 'prompt-route:home.prompt'"),
                      "The push replaced the Home route: \(app.staticTexts["fixture.home-prompt-route"].label)")
        keep("1684-home-push-tap-kept-home")
    }

    /// A push for another chat replaces Home only after Home's chat retires, so the
    /// restoring Home open cannot take the target's presentation authority.
    @MainActor
    func testPushTapForOtherChatReplacesRestoringHome() {
        continueAfterFailure = false
        let app = launchHomeThenTapPushOnForeground(["-home-push-ordinary"])
        defer { app.terminate() }
        assertSettledWithoutOpenFailure(app)
        XCTAssertTrue(waitFor(app.staticTexts["fixture.home-opened-session"], "label == 'opened-session:ordinary-session'"),
                      app.debugDescription)
        XCTAssertTrue(waitFor(app.buttons["session-context-button"], "label CONTAINS 'Manage Session'"), app.debugDescription)
        XCTAssertFalse(app.staticTexts["Conversation unavailable"].waitForExistence(timeout: 3), app.debugDescription)
        keep("1684-home-push-tap-opened-other-chat")
    }

    @MainActor
    private func launchHomeThenTapPushOnForeground(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-dashboard-workers",
                               "-dashboard-view-home", "-home-push-tap-on-foreground"] + extra
        app.launch()
        let homeButton = app.buttons["dashboard.menu"]
        XCTAssertTrue(homeButton.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(waitFor(homeButton, "value == 'Ready'"), app.debugDescription)
        homeButton.tap()
        XCTAssertTrue(app.textViews["Message input"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(waitFor(app.buttons["session-context-button"], "label CONTAINS 'Manage Home'"), app.debugDescription)
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
