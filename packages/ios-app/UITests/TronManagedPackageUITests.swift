import XCTest

/// Real Settings/Extensions views decode package ownership from a fixture socket.
/// Known, absent and future ownership all traverse the production catalog owner.
final class TronManagedPackageUITests: XCTestCase {
    @MainActor func testManagedPackagesHaveIdentityAndNoMutationMenu() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-settings-renderer-fixture"]
            if appearance == "dark" { app.launchArguments.append("-settings-renderer-dark") }
            app.launch()
            defer { app.terminate() }
            let extensions = app.buttons["Extensions"].firstMatch
            for _ in 0..<4 where !extensions.isHittable { app.swipeUp() }
            XCTAssertTrue(extensions.waitForExistence(timeout: 10), app.debugDescription)
            extensions.tap()
            let managed = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "pi-subagents.")).firstMatch
            XCTAssertTrue(managed.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(managed.label.contains("Managed by Tron"))
            XCTAssertTrue(managed.label.contains("0.76.1-test"))
            XCTAssertFalse(app.buttons["Manage pi-subagents"].exists)
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Future managed package.")).firstMatch.exists)
            XCTAssertFalse(app.buttons["Manage Future managed package"].exists,
                           "Unknown management owners decode and remain non-mutable")
            keepScreenshot(app, "626-\(appearance)-installed")
            managed.tap()
            XCTAssertTrue(app.staticTexts["Installed package"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Skills"].exists)
            XCTAssertTrue(app.staticTexts["Prompts"].exists)
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "tron:pi-subagents@")).firstMatch.exists)
            keepScreenshot(app, "626-\(appearance)-detail")
            app.buttons["Done"].firstMatch.tap()
            let ordinary = app.buttons["Manage npm:ordinary-package"]
            XCTAssertTrue(ordinary.waitForExistence(timeout: 5), "An unmanaged row keeps its existing controls")
            ordinary.tap()
            XCTAssertTrue(app.buttons["Update"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Remove"].exists)
            app.terminate()
        }
    }

    @MainActor private func keepScreenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
