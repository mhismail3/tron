import XCTest

/// The dashboard's custom title sits in the top safe area, where iPadOS
/// windowed mode draws the window controls over the top-leading corner. The
/// title clears the system chrome in that corner: the status bar on every
/// device, and the window controls at rest and collapsed when they exist.
@MainActor
final class TronDashboardWindowControlsUITests: XCTestCase {
    func testDashboardTitleClearsWindowControlsAtRestAndScrolled() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-dashboard-workers", "-dashboard-view-home"]
        app.launch()
        defer { app.terminate() }
        let title = app.staticTexts["dashboard.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 1.5)

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let controls = springboard.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'window-controls:'"))
        let screen = springboard.frame
        let window = app.windows.firstMatch
        // iPadOS remembers a window's size across launches, so a previous run
        // may leave the app windowed; start from whichever state it is in.
        if window.frame.width >= screen.width {
            XCTAssertEqual(controls.count, 0, "A full-screen window shows no window controls")
            assertBelowStatusBar(title, app: app, springboard: springboard, state: "full-screen")
            // Windowed Apps mode shows a resize grabber on every app window;
            // other modes have no window controls to clear.
            guard springboard.otherElements["resize-grabber"].exists else { return }
            let full = window.frame
            let origin = springboard.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: full.maxX - 6, dy: full.maxY - 6))
                .press(forDuration: 0.6, thenDragTo: origin.withOffset(CGVector(dx: full.midX, dy: full.midY)))
        }
        XCTAssertTrue(controls.firstMatch.waitForExistence(timeout: 5), "The resized window shows its window controls")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertLessThan(window.frame.width, screen.width, "The window is resized, not full screen")
        // Stage Manager may show other apps' controls; ours sit inside our window.
        let ownControls = controls.allElementsBoundByIndex.map(\.frame).first { window.frame.contains($0) }
        guard let controlFrame = ownControls else {
            return XCTFail("No window controls inside the app window \(window.frame)")
        }
        let restFrame = title.frame
        assertClear(restFrame, of: controlFrame, state: "rest", window: window.frame)

        app.collectionViews.firstMatch.swipeUp(velocity: .slow)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertLessThan(title.frame.minY, restFrame.minY, "Scrolling collapsed the title")
        assertClear(title.frame, of: controlFrame, state: "scrolled", window: window.frame)
    }

    private func assertBelowStatusBar(_ title: XCUIElement, app: XCUIApplication, springboard: XCUIApplication, state: String) {
        let statusBar = [app.statusBars.firstMatch, springboard.statusBars.firstMatch].first(where: \.exists)
        guard let statusBar else { return XCTFail("No status bar to measure the title against (\(state))") }
        attach("dashboard-window-controls-\(state)", geometry: "window=\(app.windows.firstMatch.frame); statusBar=\(statusBar.frame); title=\(title.frame)")
        XCTAssertGreaterThanOrEqual(
            title.frame.minY, statusBar.frame.maxY,
            "The dashboard title \(title.frame) sits below the status bar \(statusBar.frame) (\(state))"
        )
    }

    private func assertClear(_ title: CGRect, of controls: CGRect, state: String, window: CGRect) {
        attach("dashboard-window-controls-\(state)", geometry: "window=\(window); controls=\(controls); title=\(title)")
        XCTAssertFalse(
            title.intersects(controls),
            "The dashboard title \(title) overlaps the window controls \(controls) (\(state))"
        )
    }

    private func attach(_ name: String, geometry: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let text = XCTAttachment(string: geometry)
        text.name = "\(name)-geometry"
        text.lifetime = .keepAlways
        add(text)
    }
}
