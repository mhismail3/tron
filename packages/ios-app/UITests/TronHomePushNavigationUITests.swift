import XCTest

/// A push for the Home chapter, tapped while Home is the presented chat (#1684).
/// The tap arrives as the scene returns to the foreground, while the mounted Home
/// chat is restoring its open on the replacement connection — the device journey
/// that showed "The conversation changed while opening".
final class TronHomePushNavigationUITests: XCTestCase {
    @MainActor
    func testPushTapForPresentedHomeChapterKeepsHomeOpen() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-dashboard-workers",
                               "-dashboard-view-home", "-home-push-tap-on-foreground"]
        app.launch(); defer { app.terminate() }
        let homeButton = app.buttons["dashboard.menu"]
        XCTAssertTrue(homeButton.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(waitFor(homeButton, "value == 'Ready'"), app.debugDescription)
        homeButton.tap()
        let composer = app.textViews["Message input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 15), app.debugDescription)
        let manage = app.buttons["session-context-button"]
        XCTAssertTrue(waitFor(manage, "label CONTAINS 'Manage Home'"), app.debugDescription)

        let push = app.staticTexts["fixture.home-push"]
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        // The tap is consumed and the chat settles; the same conversation stays
        // the Home route, and it never reports a benign open as changed.
        XCTAssertTrue(waitFor(push, "label BEGINSWITH 'push:consumed'", timeout: 15),
                      "The push was never consumed after foreground restore: \(push.label)")
        let unavailable = app.staticTexts["Conversation unavailable"]
        XCTAssertFalse(unavailable.waitForExistence(timeout: 8), "Push open failed: \(app.debugDescription)")
        XCTAssertTrue(composer.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(waitFor(manage, "label CONTAINS 'Manage Home'"), "The push replaced the Home route: \(manage.label)")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "1684-home-push-tap-settled"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func waitFor(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 10) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)],
                       timeout: timeout) == .completed
    }
}
