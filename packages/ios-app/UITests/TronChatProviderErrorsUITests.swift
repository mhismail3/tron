import XCTest

final class TronChatProviderErrorsUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }
    @MainActor func testProviderErrorRunUpdatesLiveAndSurvivesReopen() {
        let app = launch()
        let overload = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Anthropic is overloaded")).firstMatch
        XCTAssertTrue(overload.waitForExistence(timeout: 20), app.debugDescription)
        app.buttons["Live error"].tap()
        let grouped = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Anthropic is overloaded", "2 errors")).firstMatch
        XCTAssertTrue(grouped.waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["Settle error"].tap()
        XCTAssertTrue(grouped.waitForExistence(timeout: 10))
        app.buttons["Mixed error"].tap()
        let mixed = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Provider errors", "3 errors")).firstMatch
        XCTAssertTrue(mixed.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat-error-run-")).count, 1)
        app.buttons["fixture.reopen-chat"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "fixture.gateway", "opens:2")).firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(mixed.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat-error-run-")).count, 1)
        app.buttons["Continue boundary"].tap()
        XCTAssertTrue(app.staticTexts["Continue"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat-error-run-")).count, 2)
        keep(app, "live-reload-boundary")
    }

    @MainActor func testProviderErrorSheetsShowBreakdownPrettyJSONAndRawText() {
        let app = launch()
        let overload = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Anthropic is overloaded")).firstMatch
        XCTAssertTrue(overload.waitForExistence(timeout: 20), app.debugDescription)
        overload.tap()
        let json = app.staticTexts["chat-error-body-error-first"]
        XCTAssertTrue(json.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(json.label.contains("\n  \"error\""), json.label)
        XCTAssertTrue(json.label.contains("req_error-first"))
        XCTAssertTrue(app.descendants(matching: .any)["chat-error-request-id-error-first"].label.contains("req_error-first"))
        keep(app, "single-pretty-json")
        app.buttons["Done"].tap()
        app.buttons["Mixed error"].tap()
        let mixed = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Provider errors")).firstMatch
        XCTAssertTrue(mixed.waitForExistence(timeout: 10))
        app.buttons["Delayed error"].tap()
        mixed.tap()
        let summary = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "chat-error-summary", "2 errors · 2 distinct errors")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 10), app.debugDescription)
        let raw = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "chat-error-body-", "Request timed out after 60 seconds")).firstMatch
        XCTAssertTrue(raw.waitForExistence(timeout: 10), app.debugDescription)
        keep(app, "mixed-raw-text")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "chat-error-summary", "3 errors · 2 distinct errors")).firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["Done"].exists, "Live update must keep the same sheet open")
    }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-chat-haptics-fixture", "-chat-provider-errors", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }
    @MainActor private func keep(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "provider-error-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
