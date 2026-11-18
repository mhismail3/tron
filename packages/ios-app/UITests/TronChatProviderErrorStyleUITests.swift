import XCTest
import UIKit

final class TronChatProviderErrorStyleUITests: XCTestCase {

    @MainActor func testStandardErrorDetailsKeepSelectablePayload() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        let single = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat-error-run-")).firstMatch
        XCTAssertTrue(single.waitForExistence(timeout: 20), app.debugDescription)
        single.tap()
        let body = app.staticTexts["chat-error-body-error-first"]
        XCTAssertTrue(body.waitForExistence(timeout: 10), app.debugDescription)
        app.swipeUp()
        body.press(forDuration: 1.1)
        let copy = app.menuItems["Copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10), "The standard code inset must retain native selection: \(app.debugDescription)")
        keep(app, "selectable-json")
        copy.tap()
        XCTAssertTrue(app.buttons["Done"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(single.waitForExistence(timeout: 10), "Done must return to the unchanged transcript")
    }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-chat-haptics-fixture", "-chat-provider-errors", "-error-style-preview",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    @MainActor private func keep(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "1993-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
