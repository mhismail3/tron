import XCTest

/// Visual evidence only. These simulator frames do not prove frame-perfect motion
/// or physical-device behavior; behavioral regressions are a separate phase.
final class TronUsageWorkspaceCaptureUITests: XCTestCase {
    @MainActor func testCaptureLight() { capture(dark: false, reducedMotion: false) }
    @MainActor func testCaptureDark() { capture(dark: true, reducedMotion: false) }
    @MainActor func testCaptureReducedMotion() { capture(dark: false, reducedMotion: true) }

    @MainActor private func capture(dark: Bool, reducedMotion: Bool) {
        let mode = reducedMotion ? "reduced-motion" : dark ? "dark" : "light"
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-dashboard-workers", "-dashboard-view-home",
                               "-home-dashboard-usage-delay", "-fixture-appearance", dark ? "dark" : "light"]
        if dark { app.launchArguments += ["-home-dark"] }
        if reducedMotion { app.launchArguments += ["-usage-capture-reduced-motion"] }
        app.launch()
        let card = app.buttons["home-usage-card"]
        _ = card.waitForExistence(timeout: 10)
        for frame in 0..<12 {
            shot("usage-\(mode)-\(String(format: "%02d", frame))")
            Thread.sleep(forTimeInterval: 0.55)
        }
        app.terminate()
        if reducedMotion { return }
        app.launchArguments = ["-tron-session-configuration-fixture", "-settings-scope-review", "-manage-session-review",
                               "-workspace-capture-delay", "-fixture-appearance", dark ? "dark" : "light"]
        app.launch()
        _ = app.buttons["Stop session"].waitForExistence(timeout: 10)
        app.buttons["Stop session"].tap()
        let workspace = app.buttons["Workspace"]
        _ = workspace.waitForExistence(timeout: 10)
        Thread.sleep(forTimeInterval: 2)
        shot("workspace-\(mode)-before")
        app.buttons["manage-session-rename"].tap()
        Thread.sleep(forTimeInterval: 0.6)
        shot("workspace-\(mode)-covered")
        app.buttons["Cancel"].firstMatch.tap()
        for frame in 0..<8 {
            shot("workspace-\(mode)-dismiss-\(String(format: "%02d", frame))")
            Thread.sleep(forTimeInterval: 0.15)
        }
        app.terminate()
    }

    @MainActor private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
