import XCTest

@MainActor
final class TronSheetThemePreviewUITests: XCTestCase {


    func testWorkspaceControlsFollowThePresentingTheme() {
        for mode in ["light", "dark"] {
            let app = settings(mode)
            defer { app.terminate() }
            open(app, "settings-link-Connections")
            expand(app, title: "Connections")
            open(app, "Details for Fixture")
            expand(app, title: "Fixture")
            open(app, "Configure source repository")
            XCTAssertTrue(app.buttons["Use current folder"].waitForExistence(timeout: 10))
            let title = app.navigationBars.staticTexts["/fixture/projects"].firstMatch
            for label in ["Default", "Go Up", "New Folder", "Hidden"] {
                let button = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", label)).allElementsBoundByIndex.last { $0.isHittable }!
                assertColor(app, area: button.frame, matches: title.frame, ink: true)
                assertColor(app, area: containerPatch(button.frame), matches: title.frame, ink: false)
            }
            let folder = app.buttons["Example"].frame
            assertColor(app, area: CGRect(x: folder.minX, y: folder.minY, width: 45, height: folder.height), matches: title.frame, ink: true)
            capture(app, "regression-workspace-server-\(mode)")
            app.terminate()
        }
    }

    private func settings(_ mode: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-nested", "-settings-expanded-review", "-settings-sheet-theme-review"]
        if mode == "dark" { app.launchArguments.append("-settings-renderer-dark") }
        app.launch()
        XCTAssertTrue(app.buttons["Open Settings"].waitForExistence(timeout: 15))
        app.buttons["Open Settings"].tap()
        expand(app, title: "Global Settings")
        return app
    }

    private func containerPatch(_ frame: CGRect) -> CGRect {
        CGRect(x: frame.midX - 2, y: frame.minY + 4, width: 5, height: 3)
    }

    private func assertColor(_ app: XCUIApplication, area: CGRect, matches title: CGRect, ink: Bool,
                             file: StaticString = #filePath, line: UInt = #line) {
        let expected = chroma(color(app, area: title, ink: true))
        let actual = chroma(color(app, area: area, ink: ink))
        XCTAssertLessThan(zip(expected, actual).map { abs($0 - $1) }.max() ?? 1, 0.28,
                          "Rendered \(ink ? "ink" : "container") chroma \(actual) differs from sheet title \(expected)", file: file, line: line)
    }

    private func chroma(_ rgb: [Double]) -> [Double] {
        let low = rgb.min()!, range = rgb.max()! - low
        return rgb.map { ($0 - low) / max(range, 0.001) }
    }

    private func color(_ app: XCUIApplication, area: CGRect, ink: Bool) -> [Double] {
        let source = app.screenshot().image.cgImage!
        let scale = CGFloat(source.width) / app.windows.firstMatch.frame.width
        let crop = source.cropping(to: area.applying(CGAffineTransform(scaleX: scale, y: scale)))!
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        let context = CGContext(data: &pixels, width: crop.width, height: crop.height, bitsPerComponent: 8,
            bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        var sum = [0.0, 0.0, 0.0], count = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let rgb = [Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2])]
            if ink && rgb.max()! - rgb.min()! < 60 { continue }
            for c in 0..<3 { sum[c] += rgb[c] / 255 }
            count += 1
        }
        XCTAssertGreaterThan(count, 0, "No rendered color in \(area)")
        return sum.map { $0 / max(count, 1) }
    }

    private func open(_ app: XCUIApplication, _ id: String) {
        let button = app.buttons[id].firstMatch
        for _ in 0..<7 {
            if button.exists && button.isHittable { button.tap(); return }
            app.swipeUp()
        }
        for _ in 0..<7 {
            if button.exists && button.isHittable { button.tap(); return }
            app.swipeDown()
        }
        XCTFail("Cannot open \(id): \(app.debugDescription)")
    }

    private func expand(_ app: XCUIApplication, title: String) {
        let title = app.navigationBars.staticTexts[title].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), app.debugDescription)
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)))
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "presentation settles")], timeout: 1)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "1611-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
