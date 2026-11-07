import XCTest

/// In iPadOS windowed mode the system draws the window controls over the
/// window's top-leading corner. The dashboard's custom title must clear them
/// at rest and when collapsed by scrolling. Runs on an iPad simulator in
/// Windowed Apps mode; elsewhere the system draws no controls and it skips.
@MainActor
final class TronDashboardWindowControlsUITests: XCTestCase {
    func testDashboardTitleClearsWindowControlsAtRestAndScrolled() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Window controls exist only on iPad.")
        }
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-dashboard-workers", "-dashboard-view-home"]
        app.launch()
        defer { app.terminate() }
        let title = app.staticTexts["dashboard.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15))

        // Shrink the window from its bottom-trailing corner so the system shows
        // its controls and the session list becomes taller than the window.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let window = app.windows.firstMatch.frame
        let origin = springboard.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: window.maxX - 6, dy: window.maxY - 6))
            .press(forDuration: 0.6, thenDragTo: origin.withOffset(CGVector(dx: window.midX, dy: window.midY)))
        let controls = springboard.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'window-controls:'")).firstMatch
        guard controls.waitForExistence(timeout: 5) else {
            throw XCTSkip("Run on an iPad simulator with Windowed Apps multitasking.")
        }
        Thread.sleep(forTimeInterval: 1.5)
        assertClear(title.frame, of: controls.frame, state: "rest", window: app.windows.firstMatch.frame)

        app.collectionViews.firstMatch.swipeUp(velocity: .slow)
        Thread.sleep(forTimeInterval: 1.5)
        assertClear(title.frame, of: controls.frame, state: "scrolled", window: app.windows.firstMatch.frame)
    }

    private func assertClear(_ title: CGRect, of controls: CGRect, state: String, window: CGRect) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "dashboard-window-controls-\(state)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let geometry = XCTAttachment(string: "window=\(window); controls=\(controls); title=\(title)")
        geometry.name = "dashboard-window-controls-\(state)-geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
        XCTAssertFalse(controls.isEmpty, "The system window controls have a frame (\(state))")
        XCTAssertFalse(
            title.intersects(controls),
            "The dashboard title \(title) overlaps the window controls \(controls) (\(state))"
        )
    }
}
