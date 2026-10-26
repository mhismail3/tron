import XCTest

/// Visual proposal captures, not lifecycle acceptance or persistence evidence.
@MainActor
final class TronProjectLifecyclePreviewUITests: XCTestCase {
    func testProjectLifecycleVisualProposal() {
        continueAfterFailure = false
        for size in ["normal", "xxxl"] {
            for mode in ["light", "dark"] {
                for surface in ["list", "add", "create", "trusted", "untrusted", "rename", "busy"] {
                    let app = XCUIApplication()
                    app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-expanded-review",
                        "-settings-sheet-theme-review", "-project-lifecycle-preview", surface]
                    if mode == "dark" { app.launchArguments.append("-settings-renderer-dark") }
                    app.launchArguments += ["-UIPreferredContentSizeCategoryName",
                        size == "xxxl" ? "UICTContentSizeCategoryXXXL" : "UICTContentSizeCategoryL"]
                    app.launch()
                    XCTAssertTrue(app.scrollViews["project-preview-\(surface)"].waitForExistence(timeout: 15), app.debugDescription)
                    capture(app, "project-\(surface)-\(mode)-\(size)-top")
                    if ["create", "trusted", "untrusted", "busy"].contains(surface) {
                        app.swipeUp()
                        capture(app, "project-\(surface)-\(mode)-\(size)-bottom")
                    }
                    app.terminate()
                }
            }
        }
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
