import XCTest

/// Samples the real rendered sheet surface, not a SwiftUI modifier or a replica.
/// The outer gutter excludes cards, title ink and glass buttons, exposing a
/// separate toolbar backdrop even when that backdrop hides from accessibility.
final class TronSheetBackgroundUITests: XCTestCase {
    /// Navigation-only visual checkpoint. Pixel assertions are in the regression journeys.
    @MainActor func testTopBlurVisualCheckpoint() {
        continueAfterFailure = false
        for mode in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-presentation-loading"]
                + (mode == "dark" ? ["-home-dark"] : [])
            app.launch()
            XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 15))
            app.buttons["home-pinned-row"].tap()
            let ring = app.buttons["session-context-button"]
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == true AND enabled == true"), object: ring)], timeout: 15), .completed)
            ring.tap()
            XCTAssertTrue(app.descendants(matching: .any)["home-manage-state"].waitForExistence(timeout: 30))
            capture(app, name: "manage-\(mode)")
            app.terminate()

            app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-nested", "-settings-expanded-review", "-settings-sheet-theme-review"]
                + (mode == "dark" ? ["-settings-renderer-dark"] : [])
            app.launch()
            XCTAssertTrue(app.buttons["Open Settings"].waitForExistence(timeout: 15))
            app.buttons["Open Settings"].tap()
            let models = app.buttons["settings-section-model-open"]
            XCTAssertTrue(models.waitForExistence(timeout: 10))
            models.tap()
            XCTAssertTrue(app.navigationBars.staticTexts["Models"].waitForExistence(timeout: 10))
            capture(app, name: "settings-models-\(mode)")
            app.terminate()

            app.launchArguments = ["-tron-tool-sheets-polish-fixture", "-polish-scenario", "search", "-polish-\(mode)"]
            app.launch()
            XCTAssertTrue(app.buttons["Done"].firstMatch.waitForExistence(timeout: 10))
            capture(app, name: "tool-search-\(mode)")
            app.terminate()
        }
    }

    @MainActor private func capture(_ app: XCUIApplication, name: String) {
        Thread.sleep(forTimeInterval: 1)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "1631-\(name)"; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor func testSheetBackgroundContinuousInLight() { journey(dark: false) }
    @MainActor func testSheetBackgroundContinuousInDark() { journey(dark: true) }

    @MainActor private func journey(dark: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-presentation-loading"]
            + (dark ? ["-home-dark"] : [])
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 15))
        app.buttons["home-pinned-row"].tap()
        let ring = app.buttons["session-context-button"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true"), object: ring)], timeout: 15), .completed)
        ring.tap()
        let manageDone = app.buttons["home-sheet-done-manage"]
        XCTAssertTrue(manageDone.waitForExistence(timeout: 5))
        assertStationaryBlur(app, done: manageDone, dark: dark, name: "manage")
        XCTAssertTrue(app.descendants(matching: .any)["home-manage-state"].waitForExistence(timeout: 5))
        app.descendants(matching: .any)["home-manage-tasks"].tap()
        let tasksDone = app.buttons["home-sheet-done-tasks"]
        XCTAssertTrue(tasksDone.waitForExistence(timeout: 5))
        assertStationaryBlur(app, done: tasksDone, dark: dark, name: "tasks")
        XCTAssertTrue(app.buttons["home-task-active"].waitForExistence(timeout: 5))
    }

    @MainActor private func assertStationaryBlur(_ app: XCUIApplication, done: XCUIElement, dark: Bool, name: String) {
        XCTAssertTrue(app.descendants(matching: .any)["sheet-loading"].waitForExistence(timeout: 3),
                      "The delayed real sheet read must exercise the loading reveal")
        let window = app.windows.firstMatch.frame
        let toolbarY = done.frame.midY
        // The gutter is inside the medium sheet but outside cards/buttons. Sample
        // the whole fade, not title ink or the pulse. The fixture delays reads 12s.
        let offsets: [CGFloat] = [-8, 12, 32, 52, 72]
        func profile(_ screenshot: XCUIScreenshot) -> [[Double]] {
            guard let source = screenshot.image.cgImage else { XCTFail("No screenshot pixels"); return [] }
            let scale = CGFloat(source.width) / window.width
            return offsets.map { color(source, scale: scale, x: window.minX + 14, y: toolbarY + $0) }
        }
        let first = XCUIScreen.main.screenshot()
        let baseline = profile(first)
        guard let header = baseline.first, let body = baseline.last else { return }
        let contrast = zip(header, body).map { dark ? $1 - $0 : $0 - $1 }.reduce(0, +) / 3
        XCTAssertGreaterThan(contrast, dark ? 3 : 6,
                             "\(name): pre-#1608 top blur/fade is missing: \(baseline)")
        let initial = XCTAttachment(screenshot: first)
        initial.name = "1631-\(name)-loading"; initial.lifetime = .keepAlways; add(initial)
        var samples = [baseline]
        var worstDelta = 0.0
        var worst = first
        let deadline = Date().addingTimeInterval(13)
        repeat {
            Thread.sleep(forTimeInterval: 0.12)
            let screenshot = XCUIScreen.main.screenshot()
            let current = profile(screenshot)
            samples.append(current)
            let delta = zip(baseline.flatMap { $0 }, current.flatMap { $0 }).map { abs($0 - $1) }.max() ?? 0
            if delta > worstDelta { worstDelta = delta; worst = screenshot }
        } while Date() < deadline
        let attachment = XCTAttachment(screenshot: worst)
        attachment.name = "1631-\(name)-largest-chrome-change"; attachment.lifetime = .keepAlways; add(attachment)
        let values = XCTAttachment(string: "\(samples)")
        values.name = "1631-\(name)-gutter-profiles"; values.lifetime = .keepAlways; add(values)
        XCTAssertLessThanOrEqual(worstDelta, 3,
                                 "\(name): toolbar fade must not slide/fade with loading content; largest RGB drift \(worstDelta)")
    }

    private func color(_ source: CGImage, scale: CGFloat, x: CGFloat, y: CGFloat) -> [Double] {
        let area = CGRect(x: x, y: y, width: 2, height: 2)
            .applying(CGAffineTransform(scaleX: scale, y: scale))
        guard let crop = source.cropping(to: area) else { XCTFail("Patch outside screenshot"); return [0, 0, 0] }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            XCTFail("Cannot read screenshot color"); return [0, 0, 0]
        }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return pixel.prefix(3).map(Double.init)
    }
}
