import XCTest

/// Capture-only hosted design review for #1641, not behavioral or Gateway acceptance.
final class TronInlineApprovalsPreviewTests: XCTestCase {
    @MainActor
    func testCaptureInlineApprovalsInLightAndDark() throws {
        let surfaces = ["chat", "request-worker", "request-single", "request-grant", "request-approved",
                        "outcome-applied", "outcome-denied", "outcome-failed", "outcome-expired"]
        for appearance in ["light", "dark"] {
            for surface in surfaces {
                let app = XCUIApplication()
                app.launchArguments = ["-tron-inline-approvals-preview", surface, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
                if appearance == "dark" { app.launchArguments.append("-preview-dark") }
                app.launch()
                let ready = surface == "chat"
                    ? app.descendants(matching: .any)["preview-request-chip"]
                    : app.buttons["Done"]
                guard ready.waitForExistence(timeout: 20) else {
                    XCTFail("Preview \(surface) did not open: \(app.debugDescription)"); app.terminate(); return
                }
                // Let the sheet finish presenting before the screenshot.
                Thread.sleep(forTimeInterval: 1.0)
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "1641-\(surface)-\(appearance)"
                attachment.lifetime = .keepAlways
                add(attachment)
                app.terminate()
            }
        }
    }
}
