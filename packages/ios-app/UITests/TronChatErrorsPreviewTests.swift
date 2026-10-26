import XCTest

/// Capture-only design review, not a behavioral regression or acceptance test.
final class TronChatErrorsPreviewTests: XCTestCase {
    @MainActor func testCaptureDesignCanvases() {
        for dark in [false, true] {
            for surface in ["pills", "single", "grouped", "mixed", "text"] {
                let app = XCUIApplication()
                app.launchArguments = ["-tron-chat-errors-preview", "-error-preview-surface", surface,
                                       "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
                if dark { app.launchArguments.append("-error-preview-dark") }
                app.launch()
                if surface == "pills" {
                    _ = app.staticTexts["Design preview · Synthetic errors"].waitForExistence(timeout: 20)
                } else {
                    _ = app.buttons["Done"].waitForExistence(timeout: 20)
                }
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "chat-errors-\(surface)-\(dark ? "dark" : "light")"
                attachment.lifetime = .keepAlways
                add(attachment)
                app.terminate()
            }
        }
    }
}
