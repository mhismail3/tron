import XCTest

/// Capture-only hosted design review, not behavioral or Gateway acceptance.
final class TronSettingsThreeLayerPreviewTests: XCTestCase {
    @MainActor
    func testCaptureThreeLayerDesignInLightAndDark() throws {
        for appearance in ["light", "dark"] {
            for surface in ["global", "changes", "manage-session", "manage-home", "session", "home", "project-row", "project-only"] {
                let app = XCUIApplication()
                app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-expanded-review",
                    "-settings-three-layer-preview", surface, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
                if appearance == "dark" { app.launchArguments.append("-settings-renderer-dark") }
                app.launch()
                guard app.staticTexts["Design preview · Synthetic values"].waitForExistence(timeout: 20) else {
                    XCTFail("Preview did not open: \(app.debugDescription)"); app.terminate(); return
                }
                capture(app, "1634-\(surface)-\(appearance)")
                if surface == "changes" {
                    app.buttons["preview-changes-filters"].tap()
                    guard app.navigationBars.staticTexts["Filters"].waitForExistence(timeout: 5) else {
                        XCTFail("Filters did not open: \(app.debugDescription)"); app.terminate(); return
                    }
                    capture(app, "1634-changes-filters-\(appearance)")
                }
                if surface == "project-row" {
                    app.buttons.matching(identifier: "preview-project-pill")
                        .matching(NSPredicate(format: "label == %@", "Set by Project settings")).firstMatch.tap()
                    guard app.navigationBars.staticTexts["Project setting"].waitForExistence(timeout: 5) else {
                        XCTFail("Project info did not open: \(app.debugDescription)"); app.terminate(); return
                    }
                    capture(app, "1634-project-info-\(appearance)")
                }
                if surface == "home" {
                    app.buttons["Models"].firstMatch.tap()
                    guard app.navigationBars.staticTexts["Models"].waitForExistence(timeout: 5) else {
                        XCTFail("Home Models did not open: \(app.debugDescription)"); app.terminate(); return
                    }
                    capture(app, "1634-home-models-\(appearance)")
                }
                app.terminate()
            }
        }
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
