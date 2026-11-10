import XCTest

@MainActor
final class TronDashboardWindowControlsUITests: XCTestCase {
    func testDashboardTitleClearsWindowControlsAtRestAndScrolled() throws {
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
        defer { restoreFullScreen(window, springboard: springboard, screen: screen) }
        if window.frame.width >= screen.width {
            XCTAssertEqual(controls.count, 0, "A full-screen window shows no window controls")
            assertBelowStatusBar(title, app: app, springboard: springboard, state: "full-screen")
            guard springboard.otherElements["resize-grabber"].exists else {
                if UIDevice.current.userInterfaceIdiom == .pad { throw XCTSkip("Windowed Apps mode is off: no window controls to clear") }
                return
            }
            let full = window.frame
            let origin = springboard.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: full.maxX - 6, dy: full.maxY - 6))
                .press(forDuration: 0.6, thenDragTo: origin.withOffset(CGVector(dx: full.midX, dy: full.midY)))
        }
        XCTAssertTrue(controls.firstMatch.waitForExistence(timeout: 5), "The resized window shows its window controls")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertLessThan(window.frame.width, screen.width, "The window is resized, not full screen")
        let ownControls = controls.allElementsBoundByIndex.map(\.frame).first { window.frame.contains($0) }
        guard let controlFrame = ownControls else {
            return XCTFail("No window controls inside the app window \(window.frame)")
        }
        let restFrame = title.frame
        assertClear(restFrame, of: controlFrame, state: "rest", window: window.frame)
        XCTAssertGreaterThanOrEqual(restFrame.minX, controlFrame.maxX, "The windowed title sits right of the window controls")

        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session-row'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        let rowRest = row.frame
        app.collectionViews.firstMatch.swipeUp(velocity: .slow)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertLessThan(row.frame.minY, rowRest.minY, "The list scrolled under the title")
        XCTAssertEqual(title.frame.minY, restFrame.minY, accuracy: 1, "The inline title stays beside the window controls when scrolled")
        XCTAssertEqual(title.frame.minX, restFrame.minX, accuracy: 1, "The inline title keeps its place right of the window controls when scrolled")
        assertClear(title.frame, of: controlFrame, state: "scrolled", window: window.frame)
    }

    private func restoreFullScreen(_ window: XCUIElement, springboard: XCUIApplication, screen: CGRect) {
        let windowed = window.frame
        guard windowed.width < screen.width else { return }
        let origin = springboard.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: windowed.maxX - 6, dy: windowed.maxY - 6))
            .press(forDuration: 0.6, thenDragTo: origin.withOffset(CGVector(dx: screen.maxX - 1, dy: screen.maxY - 1)))
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertGreaterThanOrEqual(window.frame.width, screen.width, "The window is full screen again for the next test")
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
