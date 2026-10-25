import XCTest

/// Capture-only navigation for visual approval, not behavioral acceptance.
@MainActor final class TronWorkerToolPreviewTests: XCTestCase {
    func testReport() { capture("worker-report") }
    func testCheckin() { capture("worker-checkin") }
    func testChips() { capture("worker-chips") }
    func testTools() { capture("worker-tools") }

    private func capture(_ surface: String) {
        for mode in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-expanded-review", "-six-ui-surface", surface,
                                   "-themeColor", "burgundy", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            if mode == "dark" { app.launchArguments.append("-settings-renderer-dark") }
            app.launch()
            _ = app.buttons["Done"].firstMatch.waitForExistence(timeout: 15)
            Thread.sleep(forTimeInterval: 1)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "\(surface)-\(mode)"
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
    }
}
