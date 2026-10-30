import XCTest

/// Hosted interaction-sheet journeys over the real AppModel, receipt executor and
/// fixture socket: the dedicated native change card and the generic ask_user form.
/// Gateway authorization and effects are proved by the Gateway E2E suites.
final class TronInteractionSheetUITests: XCTestCase {
    @MainActor
    private func keep(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Large detent, so a capture shows the whole request rather than its first rows.
    @MainActor
    private func expand(_ app: XCUIApplication, title: String) {
        app.navigationBars.staticTexts[title].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)))
    }

    /// Rendered native fixture + real AppModel/receipt/socket path, not proof
    /// of Gateway authorization or command effects.
    @MainActor
    func testNativeChangeCardSendsExactScopedAnswer() {
        continueAfterFailure = false
        for approved in [true, false] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-ask-user-fixture", "-tron-native-change-fixture"]
            app.launch()
            let button = app.buttons[approved ? "Approve" : "Cancel"]
            XCTAssertTrue(button.waitForExistence(timeout: 10), app.debugDescription)
            expand(app, title: "Review change")
            XCTAssertTrue(app.staticTexts["Disabled"].exists)
            XCTAssertTrue(app.staticTexts["printf 'native witness'"].exists)
            XCTAssertFalse(app.buttons["Submit all answers"].exists, "Native changes are not generic forms")
            XCTAssertTrue(button.isHittable, app.debugDescription)
            keep(app, "2128-native-change-simulator-fixture-\(approved ? "approve" : "cancel")")
            button.tap()
            let expected = "native change approved=\(approved) digest=\(String(repeating: "a", count: 64)) scope=ask-user-interaction/hosted-ask-user-epoch/1"
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", expected)).firstMatch.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(app.staticTexts["Mutation count: 1"].exists, "One native answer, no generic submission")
            app.terminate()
        }
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
