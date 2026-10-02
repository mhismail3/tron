import XCTest

/// Failure modes: an add receipt may settle after the draft changes or its Mac
/// is replaced. Neither the token follow-up nor local cleanup may use that new
/// draft/authority. A socket-only background handoff must retain unsent fields.
final class TronMCPServerSheetsUITests: XCTestCase {
    @MainActor
    func testHeldAddUsesSubmittedTokenAndPreservesNewerSameMacDraft() {
        continueAfterFailure = false
        let app = launch("mcp-held-add")
        defer { app.terminate() }
        fillAdd(app, name: "original-server", token: "fixture-original-token")
        let submitting = app.buttons.matching(identifier: "Add Server")
        submitting.element(boundBy: submitting.count - 1).tap()
        XCTAssertTrue(counters(app, owner: "original", contain: "add:1"))
        replace(app.textFields["For example, calendar"], with: "newer-draft")
        replace(app.secureTextFields["Paste token"], with: "fixture-newer-token")
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(counters(app, owner: "original", contain: "token:1"))
        XCTAssertTrue(counters(app, owner: "original", contain: "retargets:0"), "The follow-up must use the accepted payload, not the newer draft")
        XCTAssertTrue(app.textFields["For example, calendar"].exists, "Accepted completion must not dismiss newer unsent input")
        XCTAssertEqual(app.textFields["For example, calendar"].value as? String, "newer-draft")
        XCTAssertNotEqual(app.secureTextFields["Paste token"].value as? String, "Paste token", "The newer bearer-token draft must not be cleared")
        keepScreenshot(app, name: "348-mcp-original-follow-up-newer-draft-kept")
    }

    @MainActor
    func testHeldAddRevokesFormAndTokenFollowUpOnMacReplacement() {
        continueAfterFailure = false
        let app = launch("mcp-replace-mac")
        defer { app.terminate() }
        fillAdd(app, name: "original-server", token: "fixture-original-token")
        let submitting = app.buttons.matching(identifier: "Add Server")
        submitting.element(boundBy: submitting.count - 1).tap()
        XCTAssertTrue(counters(app, owner: "original", contain: "add:1"))
        replace(app.textFields["For example, calendar"], with: "unsent-old-mac-draft")
        XCUIDevice.shared.press(.home); app.activate()
        let replacement = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'replacement-integration-fixture'"), object: app.staticTexts["fixture.destination"])
        XCTAssertEqual(XCTWaiter.wait(for: [replacement], timeout: 15), .completed)
        let oldForm = app.textFields["For example, calendar"]
        XCTAssertFalse(oldForm.waitForExistence(timeout: 2), "A real authority change closes the credential form instead of retargeting it")
        XCTAssertTrue(counters(app, owner: "original", contain: "released:1"))
        XCTAssertTrue(counters(app, owner: "original", contain: "token:0"))
        XCTAssertTrue(counters(app, owner: "replacement", contain: "token:0"))
        fillAdd(app, name: "replacement-draft", token: "fixture-replacement-token")
        XCTAssertEqual(app.textFields["For example, calendar"].value as? String, "replacement-draft")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'outcome' OR label CONTAINS[c] 'cancelled'")).firstMatch.exists)
        XCTAssertTrue(counters(app, owner: "replacement", contain: "add:0 token:0"), "No old command or token may reach the replacement Mac")
        keepScreenshot(app, name: "348-mcp-new-authority-not-retargeted")
    }

    @MainActor
    func testUnsubmittedMCPDraftSurvivesSameMacBackgroundReconnect() {
        continueAfterFailure = false
        let app = launch("mcp-held-add")
        defer { app.terminate() }
        fillAdd(app, name: "unsent-draft", token: "fixture-original-token")
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(app.textFields["For example, calendar"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["For example, calendar"].value as? String, "unsent-draft")
        XCTAssertTrue(app.secureTextFields["Paste token"].exists)
        XCTAssertTrue(counters(app, owner: "original", contain: "add:0 token:0"))
        keepScreenshot(app, name: "348-mcp-unsent-draft-same-mac")
    }

    @MainActor private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-integrations-fixture", "-integrations-scenario", scenario, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); return app
    }
    @MainActor private func fillAdd(_ app: XCUIApplication, name: String, token: String) {
        XCTAssertTrue(app.buttons["Add Server"].waitForExistence(timeout: 10))
        app.buttons["Add Server"].tap()
        XCTAssertTrue(app.textFields["For example, calendar"].waitForExistence(timeout: 5))
        app.textFields["For example, calendar"].tap(); app.textFields["For example, calendar"].typeText(name)
        app.textFields["https://server.example"].tap(); app.textFields["https://server.example"].typeText("https://example.test/mcp")
        app.secureTextFields["Paste token"].tap(); app.secureTextFields["Paste token"].typeText(token)
    }
    @MainActor private func replace(_ field: XCUIElement, with text: String) {
        let app = XCUIApplication()
        if field.elementType == .textField { app.swipeDown() }
        field.tap()
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 80))
        field.typeText(text)
    }
    @MainActor private func counters(_ app: XCUIApplication, owner: String, contain value: String) -> Bool {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", value), object: app.staticTexts["fixture.mcp-\(owner)"])
        return XCTWaiter.wait(for: [expected], timeout: 10) == .completed
    }
    @MainActor private func keepScreenshot(_ app: XCUIApplication, name: String) {
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = name; capture.lifetime = .keepAlways; add(capture)
    }
}
