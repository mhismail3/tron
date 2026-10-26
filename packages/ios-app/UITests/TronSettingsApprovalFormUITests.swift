import XCTest

/// Hosted native journey through the same managed form sheet and scoped
/// extension.respond owner as ask_user. Gateway lifecycle is proved separately
/// by settings-approval-blocking.e2e.test.ts; these are simulator captures.
final class TronSettingsApprovalFormUITests: XCTestCase {
    /// Capture-only visual review. This does not replace the behavioral journey
    /// or claim that a rendered preview proves decision delivery.
    @MainActor
    func testCaptureSettingsApprovalSheetInLightAndDark() {
        for (name, appearance, large) in [
            ("light-normal", "Light", false), ("dark-normal", "Dark", false),
            ("light-xxxl", "Light", true), ("dark-xxxl", "Dark", true)
        ] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-ask-user-fixture", "-tron-settings-approval-form", "-AppleInterfaceStyle", appearance]
            if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
            app.launch()
            if app.staticTexts["Settings approval"].waitForExistence(timeout: 5) {
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "settings-approval-sheet-\(name)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            app.terminate()
        }
    }

    @MainActor
    func testDismissKeepsApprovalPendingAndReopenApprovesOnce() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-ask-user-fixture", "-tron-settings-approval-form"]
        app.launch()
        let approve = app.buttons["Approve"]
        XCTAssertTrue(approve.waitForExistence(timeout: 5), app.debugDescription)
        let window = app.windows.firstMatch
        let title = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: window.frame.midX, dy: approve.frame.midY))
        title.press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(app.buttons["settings-approval-pending-tool"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Mutation count: 0"].exists, "Dismissal must not send a decision")
        XCTAssertTrue(app.staticTexts["No mutation"].exists)
        app.buttons["settings-approval-pending-tool"].tap()
        XCTAssertTrue(approve.waitForExistence(timeout: 5), app.debugDescription)
        approve.tap()
        XCTAssertTrue(app.staticTexts["extension.respond cancelled=false selected=approve other="].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Mutation count: 1"].exists)
        app.terminate()
    }

    @MainActor
    func testApprovalContextDisplaysLiteralLinkAndImageTargets() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-ask-user-fixture", "-tron-settings-approval-form", "-tron-settings-approval-literal"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Settings approval"].waitForExistence(timeout: 5), app.debugDescription)
        let context = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "Scope: Home")).firstMatch
        XCTAssertTrue(context.exists)
        XCTAssertTrue((context.value as? String)?.contains("[label](https://example.test/full-target) ![image](https://example.test/raw.png)") == true,
                      "Approval values must not be interpreted as Markdown")
        app.buttons["Deny"].tap()
        XCTAssertTrue(app.staticTexts["Mutation count: 1"].waitForExistence(timeout: 5), app.debugDescription)
        app.terminate()
    }

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
            let context = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "Scope: Home")).firstMatch
            XCTAssertTrue(context.exists, "The sheet must show the target, layer, reason and exact diff")
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "settings-approval-sheet-\(appearance.lowercased())"
            attachment.lifetime = .keepAlways
            add(attachment)
            app.buttons["Deny"].tap()
            XCTAssertTrue(app.staticTexts["extension.respond cancelled=false selected=deny other="].waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(app.staticTexts["Mutation count: 1"].exists)
            app.terminate()
        }
    }
}
