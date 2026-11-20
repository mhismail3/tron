import XCTest

@MainActor
final class TronAccessibilityUITests: XCTestCase {
    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-accessibility-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + arguments
        app.launch()
        return app
    }

    func testSessionsMenuSettingsAndCanonicalPreferences() throws {
        let app = launch(["-fixture-dashboard", "-fixture-light"])
        defer { app.terminate() }
        let menu = app.buttons["dashboard.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["dashboard.search"].exists, "No standalone dashboard header search icon")
        XCTAssertFalse(app.buttons["Search sessions"].exists)
        menu.tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(app.buttons["Filter"].exists)
        XCTAssertFalse(app.buttons["Search"].exists)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "sessions-popup-restored-settings"
        capture.lifetime = .keepAlways
        add(capture)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["settings-link-Appearance"].tap()
        let servers = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Visible Servers")).firstMatch
        XCTAssertTrue(app.navigationBars.staticTexts["Appearance"].waitForExistence(timeout: 3), app.debugDescription)
        for _ in 0..<8 where !servers.isHittable { app.swipeUp() }
        XCTAssertTrue(servers.isHittable, app.debugDescription)
        servers.tap()
        XCTAssertTrue(app.staticTexts["Visible Servers"].waitForExistence(timeout: 3), app.debugDescription)
        let done = try XCTUnwrap(app.buttons.matching(identifier: "Done").allElementsBoundByIndex.first(where: \.isHittable))
        done.tap()
        app.buttons["settings-done"].tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        XCTAssertTrue(menu.isHittable, "Done returns to the dashboard, not a duplicate Settings owner")
    }

    func testDashboardHeaderFramesAndNativeMenuOrder() {
        for arguments in [[], ["-fixture-light", "-fixture-large-type"]] {
            let app = launch(["-fixture-dashboard"] + arguments)
            defer { app.terminate() }
            let title = app.staticTexts["Tron"]
            XCTAssertTrue(title.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertFalse(app.buttons["Tron"].exists)
            let expanded = title.frame
            XCTAssertLessThan(expanded.midX, app.frame.midX)
            let menu = app.buttons["dashboard.menu"]
            let menuFrame = menu.frame
            XCTAssertEqual(menuFrame.width, 56, accuracy: 1)
            XCTAssertEqual(menuFrame.height, 56, accuracy: 1)
            XCTAssertGreaterThan(menuFrame.midX, app.frame.midX)
            XCTAssertGreaterThan(menuFrame.midY, app.frame.height * 0.8)
            XCTAssertFalse(app.buttons["dashboard.search"].exists)
            XCTAssertFalse(app.buttons["Search sessions"].exists)
            menu.tap()
            XCTAssertFalse(app.buttons["Search"].exists)
            XCTAssertFalse(app.buttons["Filter"].exists)
            let titles = ["Settings", "Automations", "Apps", "New Session"]
            for label in titles { XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 3)) }
            XCTAssertFalse(app.buttons["Sessions"].exists, "The menu has no Sessions entry")
            let frames = titles.map { app.buttons[$0].frame }
            for (before, after) in zip(frames, frames.dropFirst()) { XCTAssertLessThan(before.midY, after.midY) }
            XCTAssertLessThanOrEqual(frames.last!.maxY, menuFrame.maxY + 1)
            XCTAssertTrue(app.buttons["New Session"].isHittable, "Creation must not require scrolling the popup")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
            XCTAssertTrue(app.buttons["Automations"].waitForNonExistence(timeout: 3), app.debugDescription)
            let scroll = app.collectionViews.firstMatch
            let viewport = scroll.frame
            let scale = devicePixelScale(app)
            app.buttons["Scroll 40"].tap()
            waitForFrame(title, y: expanded.minY - 12.5, height: expanded.height * 33 / 34)
            XCTAssertEqual(title.frame.minY, expanded.minY - 12.5, accuracy: 1)
            XCTAssertEqual(title.frame.height / expanded.height, 33.0 / 34, accuracy: 0.015)
            app.buttons["Scroll 120"].tap()
            waitForFrame(title, y: expanded.minY - 25, height: expanded.height * 32 / 34)
            XCTAssertEqual(title.frame.minY, expanded.minY - 25, accuracy: 1)
            XCTAssertEqual(title.frame.minX, expanded.minX, accuracy: 1)
            XCTAssertEqual(title.frame.height / expanded.height, 32.0 / 34, accuracy: 0.015)
            XCTAssertEqual(devicePixels(scroll.frame, scale: scale), devicePixels(viewport, scale: scale))
            XCTAssertEqual(menu.frame, menuFrame)
            app.buttons["Scroll -120"].tap()
            waitForFrame(title, y: expanded.minY, height: expanded.height * 1.06)
            XCTAssertEqual(title.frame.minY, expanded.minY, accuracy: 1)
            XCTAssertEqual(title.frame.minX, expanded.minX, accuracy: 1)
            XCTAssertEqual(title.frame.height / expanded.height, 1.06, accuracy: 0.015)
            app.buttons["Scroll 0"].tap()
            waitForFrame(title, y: expanded.minY, height: expanded.height)
            XCTAssertEqual(title.frame.height, expanded.height, accuracy: 0.5)
            XCTAssertEqual(title.frame.minY, expanded.minY, accuracy: 0.5)
            scroll.swipeDown()
            waitForFrame(title, y: expanded.minY, height: expanded.height)
            XCTAssertEqual(devicePixels(scroll.frame, scale: scale), devicePixels(viewport, scale: scale))
            XCTAssertEqual(menu.frame, menuFrame)
        }
    }

    private func devicePixelScale(_ app: XCUIApplication) -> CGFloat {
        let scale = CGFloat(XCUIScreen.main.screenshot().image.cgImage?.width ?? 0) / app.frame.width
        XCTAssertGreaterThan(scale, 0, "No screen raster to measure device pixels")
        return scale
    }

    private func devicePixels(_ frame: CGRect, scale: CGFloat) -> [Int] {
        [frame.minX, frame.minY, frame.width, frame.height].map { Int(($0 * scale).rounded()) }
    }

    private func waitForFrame(_ element: XCUIElement, y: CGFloat, height: CGFloat) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                abs(element.frame.minY - y) <= 1 && abs(element.frame.height - height) <= 1
            }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 3), .completed, XCUIApplication().debugDescription)
    }
}
