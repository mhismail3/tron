import XCTest

/// Real native delivered notifications; the hosted app mounts production chat
/// synchronization/visibility over the existing synthetic Gateway transport.
final class TronDeliveredNotificationUITests: XCTestCase {
    @MainActor func testReadingOrdinaryChatRemovesOnlyItsDeliveredPushes() {
        verify(home: false)
    }

    @MainActor func testReadingHomeRemovesDeliveredPushesForItsSealedChapters() {
        verify(home: true)
    }

    @MainActor private func verify(home: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-dashboard-workers",
            "-dashboard-view-home", "-delivered-notifications"] + (home ? ["-delivered-home"] : [])
        app.launchEnvironment["TRON_UI_LOCK_RENDERING"] = "1"
        app.launch()
        defer {
            if app.buttons["Clean delivered"].exists { app.buttons["Clean delivered"].tap() }
            app.terminate()
        }
        let delivered = app.staticTexts["fixture.delivered-notifications"]
        XCTAssertTrue(delivered.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(delivered.label, "home,ordinary,other-chat,other-machine,sealed-home,unrouted")
        XCTAssertEqual(app.staticTexts["fixture.delivered-badge"].label, "badge:7")
        if home {
            let homeButton = app.buttons["dashboard.menu"]
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Ready'"), object: homeButton)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
            homeButton.tap()
        } else {
            app.buttons["session-row-home-shell-fixture:ordinary-session"].tap()
        }
        let manage = app.buttons["session-context-button"]
        XCTAssertTrue(manage.waitForExistence(timeout: 20), app.debugDescription)
        let routed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", home ? "Manage Home" : "Manage Session"), object: manage)
        XCTAssertEqual(XCTWaiter.wait(for: [routed], timeout: 15), .completed, app.debugDescription)
        app.buttons["Inspect delivered"].tap()
        let remaining = home ? "ordinary,other-chat,other-machine,unrouted"
            : "home,other-chat,other-machine,sealed-home,unrouted"
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", remaining), object: delivered)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 15), .completed)
        XCTAssertEqual(app.staticTexts["fixture.delivered-badge"].label, "badge:0")
        app.buttons["Deliver later"].tap()
        let later = home ? "later,ordinary,other-chat,other-machine,unrouted"
            : "home,later,other-chat,other-machine,sealed-home,unrouted"
        let retained = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", later), object: delivered)
        XCTAssertEqual(XCTWaiter.wait(for: [retained], timeout: 15), .completed)
        app.buttons["Inspect delivered"].tap()
        XCTAssertEqual(delivered.label, later)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = home ? "1304-home-delivered-read" : "1304-chat-delivered-read"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
