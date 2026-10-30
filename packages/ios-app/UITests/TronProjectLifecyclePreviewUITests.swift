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

    func testProjectActionApprovalVisualProposal() {
        continueAfterFailure = false
        for size in ["normal", "xxxl"] {
            for mode in ["light", "dark"] {
                for surface in ["archive", "untrust", "trust-review", "rename-review"] {
                    let app = launch(surface: surface, mode: mode, size: size)
                    XCTAssertTrue(app.buttons["change-review-approve"].waitForExistence(timeout: 15), app.debugDescription)
                    capture(app, "project-\(surface)-\(mode)-\(size)-top")
                    app.swipeUp()
                    capture(app, "project-\(surface)-\(mode)-\(size)-bottom")
                    app.terminate()
                }
            }
        }
    }

    func testProjectDrillInsReturnThroughTheirSubSheets() {
        continueAfterFailure = false
        let app = launch(surface: "list", mode: "light", size: "normal")
        defer { app.terminate() }
        open(app, "Example")
        title(app, "Example")
        capture(app, "project-route-detail-sub-sheet")
        open(app, "Rename Project")
        title(app, "Rename Project")
        capture(app, "project-route-rename-sub-sheet")
        close(app)
        title(app, "Example")
        for operation in ["archive", "untrust"] {
            open(app, "project-preview-\(operation)")
            XCTAssertTrue(app.buttons["change-review-approve"].waitForExistence(timeout: 10))
            capture(app, "project-route-\(operation)-approval-sub-sheet")
            app.navigationBars.staticTexts["Review change"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
            title(app, "Example")
        }
        close(app)
        title(app, "Trusted Projects")
        open(app, "Add Project")
        title(app, "Add Project")
        open(app, "Create Project")
        title(app, "Create Project")
        capture(app, "project-route-create-sub-sheet")
        close(app)
        title(app, "Add Project")
        open(app, "project-preview-existing")
        XCTAssertTrue(app.buttons["Use current folder"].waitForExistence(timeout: 10))
        app.buttons["Use current folder"].tap()
        title(app, "Add Project")
        close(app)
        title(app, "Trusted Projects")
    }

    private func launch(surface: String, mode: String, size: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-expanded-review", "-settings-sheet-theme-review",
            "-project-lifecycle-preview", surface, "-UIPreferredContentSizeCategoryName",
            size == "xxxl" ? "UICTContentSizeCategoryXXXL" : "UICTContentSizeCategoryL"]
        if mode == "dark" { app.launchArguments.append("-settings-renderer-dark") }
        app.launch()
        return app
    }

    private func close(_ app: XCUIApplication) {
        // Covered sheet chrome can retain a second AX representation of Done.
        // Match the shared sheet-preview convention: use the last hittable target.
        guard let button = app.buttons.matching(NSPredicate(format: "label == 'Done'"))
            .allElementsBoundByIndex.last(where: { $0.isHittable }) else {
            XCTFail("No hittable Done button in the presented sheet")
            return
        }
        button.tap()
    }

    private func title(_ app: XCUIApplication, _ text: String) {
        XCTAssertTrue(app.navigationBars.staticTexts[text].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
    }

    private func open(_ app: XCUIApplication, _ identifier: String) {
        let button = app.buttons[identifier].firstMatch
        for _ in 0..<5 {
            if button.exists && button.isHittable { button.tap(); return }
            app.swipeUp()
        }
        XCTFail("Missing drill-in: \(identifier)\n\(app.debugDescription)")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
