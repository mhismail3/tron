import XCTest

/// Hosted native journey through the same managed form sheet and scoped
/// extension.respond owner as ask_user. Gateway lifecycle is proved separately
/// by settings-approval-blocking.e2e.test.ts; these are simulator captures.
final class TronSettingsApprovalFormUITests: XCTestCase {
    @MainActor
    func testSettingsApprovalSheetPresentsAutomaticallyAndSubmitsDeny() {
        continueAfterFailure = false
        for appearance in ["Light", "Dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-ask-user-fixture", "-tron-settings-approval-form", "-AppleInterfaceStyle", appearance]
            app.launch()
            XCTAssertTrue(app.staticTexts["Settings approval"].waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(app.buttons["Approve"].exists)
            XCTAssertTrue(app.buttons["Deny"].exists)
            let context = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Scope: Home")).firstMatch
            XCTAssertTrue(context.exists, "The sheet must show the target, layer, reason and exact diff")
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "settings-approval-sheet-\(appearance.lowercased())"
            attachment.lifetime = .keepAlways
            add(attachment)
            app.buttons["Deny"].tap()
            app.buttons["Submit all answers"].tap()
            XCTAssertTrue(app.staticTexts["extension.respond cancelled=false selected=deny other="].waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(app.staticTexts["Mutation count: 1"].exists)
            app.terminate()
        }
    }
}
