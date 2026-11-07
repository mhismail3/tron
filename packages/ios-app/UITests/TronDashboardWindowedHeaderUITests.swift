import XCTest

/// The dashboard header windowed versus full screen. A simulator window cannot
/// enter Stage Manager, so the windowed case feeds the layout the corner
/// footprint the system reports (`-tron-window-controls-inset W,H`, hosted
/// builds only); detection itself reads `containerCornerInsets`, which only a
/// windowed iPad scene fills.
@MainActor
final class TronDashboardWindowedHeaderUITests: XCTestCase {
    private func launch(_ extra: [String], _ orientation: UIDeviceOrientation = .landscapeLeft) -> XCUIApplication {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-dashboard-view-home"] + extra
        app.launch()
        return app
    }

    func testWindowedTitleSitsInlineBesideTheLightsAtSeveralControlSizes() throws {
        for (inset, orientation) in [("72,40", UIDeviceOrientation.landscapeLeft), ("96,44", .landscapeLeft), ("72,40", .portrait)] {
            try windowed(inset, orientation)
        }
    }

    private func windowed(_ inset: String, _ orientation: UIDeviceOrientation) throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Windowed mode is an iPad scene state")
        let app = launch(["-tron-window-controls-inset", inset], orientation)
        defer { app.terminate() }
        let title = app.staticTexts["dashboard.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15), app.debugDescription)
        Thread.sleep(forTimeInterval: 1.5)
        let frame = title.frame
        keep(app, "windowed-header-rest", "title=\(frame)")
        XCTAssertGreaterThanOrEqual(frame.minX, Double(inset.split(separator: ",")[0])!, "The title sits right of the window controls: \(frame)")
        let centre = Double(inset.split(separator: ",")[1])! / 2
        XCTAssertEqual(frame.midY, centre, accuracy: 4, "The title is vertically centred with the lights: \(frame)")
        let list = app.collectionViews.firstMatch
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session-row'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertGreaterThanOrEqual(row.frame.minY, frame.maxY - 1, "Nothing overlaps the title: row \(row.frame) title \(frame)")
        list.swipeUp(velocity: .slow)
        Thread.sleep(forTimeInterval: 1)
        keep(app, "windowed-header-scrolled", "title=\(title.frame)")
        XCTAssertEqual(title.frame.midY, centre, accuracy: 4, "The inline title stays centred with the lights when scrolled")
    }

    func testFullScreenKeepsTheLargeHeader() throws {
        let app = launch([])
        defer { app.terminate() }
        let title = app.staticTexts["dashboard.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15), app.debugDescription)
        Thread.sleep(forTimeInterval: 1.5)
        let frame = title.frame
        keep(app, "fullscreen-header", "title=\(frame)")
        XCTAssertEqual(frame.minX, 20, accuracy: 2, "The large header keeps its 20 pt leading margin")
        XCTAssertGreaterThan(frame.height, 36, "The large 34 pt header is kept: \(frame)")
    }

    private func keep(_ app: XCUIApplication, _ name: String, _ geometry: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        let text = XCTAttachment(string: geometry)
        text.name = "\(name)-geometry"
        text.lifetime = .keepAlways
        add(text)
    }
}
