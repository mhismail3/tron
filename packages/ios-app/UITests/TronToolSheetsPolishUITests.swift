import XCTest

/// Bounded UI-first review capture, not behavioral acceptance of replay or
/// Gateway persistence. The follow-up real-Gateway journey owns that proof.
final class TronToolSheetsPolishUITests: XCTestCase {
    @MainActor func testCaptureLightAndDarkReviewSurfaces() {
        continueAfterFailure = false
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            for scenario in ["ask", "search", "delegate", "context-long", "context-short", "prompt", "short-prompt"] {
                let app = XCUIApplication()
                app.launchArguments = ["-tron-tool-sheets-polish-fixture", "-polish-scenario", scenario,
                                       dark ? "-polish-dark" : "-polish-light", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
                app.launch()
                XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
                // Wait for the actual sheet or rendered prompt before capturing.
                if scenario == "prompt" || scenario == "short-prompt" {
                    XCTAssertTrue(app.staticTexts["Transcript presentation review"].waitForExistence(timeout: 10))
                } else {
                    XCTAssertTrue(app.buttons["Done"].firstMatch.waitForExistence(timeout: 10))
                }
                capture(app, "\(scenario)-\(mode)")
                if scenario == "delegate" {
                    app.swipeUp()
                    capture(app, "delegate-models-\(mode)")
                }
                if scenario == "prompt" {
                    let prompt = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Fix: attaching photos'")).firstMatch
                    XCTAssertTrue(prompt.waitForExistence(timeout: 5), app.debugDescription)
                    prompt.tap()
                    XCTAssertTrue(app.staticTexts["Prompt"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
                    capture(app, "prompt-full-content-\(mode)")
                }
                app.terminate()
            }
            let app = XCUIApplication()
            app.launchArguments = ["-tron-chat-display-fixture", "-chat-display-inline-group",
                                   dark ? "-polish-dark" : "-polish-light", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()
            let first = app.buttons["Open Home dashboard after the fix photo preview"]
            XCTAssertTrue(first.waitForExistence(timeout: 25), app.debugDescription)
            capture(app, "display-inline-\(mode)")
            first.tap()
            XCTAssertTrue(app.buttons["Technical details"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
            capture(app, "display-preview-\(mode)")
            app.terminate()
        }
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        // Let the native sheet and media settle, independent of content reads.
        Thread.sleep(forTimeInterval: 0.7)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
