import XCTest

final class TronChatProviderErrorStyleUITests: XCTestCase {
    /// Actual ChatView/native sheets with synthetic Gateway facts. Capture only;
    /// this method is not behavioral acceptance or physical-device evidence.
    @MainActor func testCaptureActualErrorPresentation() {
        let phase = ProcessInfo.processInfo.environment["TRON_ERROR_PREVIEW_PHASE"] ?? "preview"
        for dark in [false, true] {
            let app = launch(dark: dark)
            let mode = dark ? "dark" : "light"
            let single = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Anthropic is overloaded")).firstMatch
            _ = single.waitForExistence(timeout: 20)
            keep(app, "\(phase)-\(mode)-single-pill")
            single.tap()
            _ = app.buttons["Done"].waitForExistence(timeout: 20)
            keep(app, "\(phase)-\(mode)-single-sheet")
            app.buttons["Done"].tap()
            app.buttons["Live error"].tap()
            let grouped = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Anthropic is overloaded", "2 errors")).firstMatch
            _ = grouped.waitForExistence(timeout: 10)
            app.buttons["Settle error"].tap()
            keep(app, "\(phase)-\(mode)-grouped-pill")
            grouped.tap()
            _ = app.buttons["Done"].waitForExistence(timeout: 20)
            app.swipeUp()
            keep(app, "\(phase)-\(mode)-grouped-sheet")
            app.buttons["Done"].tap()
            app.buttons["Mixed error"].tap()
            let mixed = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Provider errors")).firstMatch
            _ = mixed.waitForExistence(timeout: 10)
            keep(app, "\(phase)-\(mode)-mixed-pill")
            mixed.tap()
            _ = app.buttons["Done"].waitForExistence(timeout: 20)
            keep(app, "\(phase)-\(mode)-mixed-sheet")
            app.swipeUp()
            keep(app, "\(phase)-\(mode)-mixed-details")
            app.terminate()
        }
    }

    @MainActor private func launch(dark: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-chat-haptics-fixture", "-chat-provider-errors", "-error-style-preview",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if dark { app.launchArguments.append("-error-preview-dark") }
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
