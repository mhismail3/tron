import XCTest

/// Real rendered Home controls (the bottom of Home Settings) in both supported appearances.
final class TronHomeControlsUITests: XCTestCase {
    /// Compare rendered glyph colors, not a test-only accessibility style label.
    @MainActor func testDisableHomeSubtitleMatchesDestructiveTitle() {
        continueAfterFailure = false
        for mode in ["light", "dark"] {
            let app = openHomeSettings(mode: mode); defer { app.terminate() }
            let disable = element(app, "home-manage-disable")
            for _ in 0..<5 where !disable.isHittable || disable.frame.maxY > app.frame.maxY - 50 {
                app.swipeUp()
            }
            XCTAssertTrue(disable.isHittable)
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "disable-home-subtitle-\(mode)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            // Default-size labels occupy separate halves of this two-line row.
            // Exclude the leading icon so it cannot make a neutral subtitle pass.
            let title = ink(app, disable, crop: { frame in
                CGRect(x: frame.minX + 56, y: frame.minY,
                       width: frame.width - 56, height: frame.height / 2)
            })
            let subtitle = ink(app, disable, crop: { frame in
                CGRect(x: frame.minX + 56, y: frame.midY,
                       width: frame.width - 56, height: frame.height / 2)
            })
            XCTAssertGreaterThan(title[0] - max(title[1], title[2]), 0.3, "Destructive title is red in \(mode)")
            XCTAssertLessThan(zip(title, subtitle).map { abs($0 - $1) }.max()!, 0.12,
                              "Disable Home's subtitle matches its destructive title in \(mode): \(subtitle) vs \(title)")
        }
    }

    /// Pause is a neutral hold: its icon, title and subtitle carry no accent hue,
    /// in light and dark and at an accessibility text size.
    @MainActor func testPauseMemoryRowIsNeutralGray() {
        continueAfterFailure = false
        for mode in ["light", "dark"] {
            for large in [false, true] {
                let app = openHomeSettings(mode: mode, accessibilityType: large); defer { app.terminate() }
                let pause = element(app, "home-manage-pause")
                XCTAssertTrue(pause.waitForExistence(timeout: 8), app.debugDescription)
                for _ in 0..<12 where !pause.isHittable || pause.frame.maxY > app.frame.maxY - 50 { app.swipeUp() }
                XCTAssertTrue(pause.isHittable, app.debugDescription)
                let name = "pause-memory-\(mode)\(large ? "-accessibility" : "")"
                let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                screenshot.name = name
                screenshot.lifetime = .keepAlways
                add(screenshot)
                let (ink, hued) = neutrality(app, pause.frame.insetBy(dx: 2, dy: 2))
                XCTAssertGreaterThan(ink, 40, "\(name): the row's labels render")
                XCTAssertLessThan(Double(hued), Double(ink) * 0.03, "\(name): \(hued) of \(ink) ink pixels carry an accent hue")
            }
        }
    }

    @MainActor private func openHomeSettings(mode: String, accessibilityType: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
            + (mode == "dark" ? ["-home-dark"] : [])
            + (accessibilityType ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"] : [])
        app.launch()
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 15))
        app.buttons["home-pinned-row"].tap()
        let ring = app.buttons["session-context-button"]
        XCTAssertTrue(waitFor(ring, "enabled == true"))
        open(app, ring, ready: "home-manage-state", name: "manage")
        let settings = element(app, "home-manage-settings")
        for _ in 0..<8 where settings.exists && (!settings.isHittable || settings.frame.maxY > app.frame.maxY - 50) { app.swipeUp() }
        XCTAssertFalse(element(app, "home-manage-pause").exists, "Pause is not a Manage Home row")
        XCTAssertFalse(element(app, "home-manage-disable").exists, "Disable is not a Manage Home row")
        let manage = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        manage.name = "manage-home-\(mode)\(accessibilityType ? "-accessibility" : "")"
        manage.lifetime = .keepAlways
        add(manage)
        open(app, settings, ready: "home-settings-controls", name: "Home Settings")
        return app
    }

    /// Ink pixels (far from the row's median luminance) and how many of them are
    /// hued (channel spread above 60/255): glyphs, not the material behind them.
    @MainActor private func neutrality(_ app: XCUIApplication, _ area: CGRect) -> (ink: Int, hued: Int) {
        let window = app.windows.firstMatch.frame.width
        guard let source = XCUIScreen.main.screenshot().image.cgImage,
              let crop = source.cropping(to: area.applying(CGAffineTransform(scaleX: CGFloat(source.width) / window,
                                                                              y: CGFloat(source.width) / window))) else {
            XCTFail("No pixels for \(area)"); return (0, 0)
        }
        let width = crop.width, height = crop.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            .draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        var luma: [Int] = [], spread: [Int] = []
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            luma.append((r * 299 + g * 587 + b * 114) / 1000)
            spread.append(max(r, g, b) - min(r, g, b))
        }
        let median = luma.sorted()[luma.count / 2]
        var ink = 0, hued = 0
        for index in luma.indices where abs(luma[index] - median) > 50 {
            ink += 1
            if spread[index] > 60 { hued += 1 }
        }
        return (ink, hued)
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Taps a row and waits for the sheet it opens.
    @MainActor private func open(_ app: XCUIApplication, _ row: XCUIElement, ready: String, name: String) {
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(name)\n\(app.debugDescription)")
        row.tap()
        XCTAssertTrue(element(app, ready).waitForExistence(timeout: 8), "\(ready)\n\(app.debugDescription)")
    }

    private func waitFor(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 10) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)], timeout: timeout) == .completed
    }

    /// The average color of an element's saturated (inked) pixels: a title's
    /// glyphs or a row's icon, never the sheet material behind them.
    @MainActor private func ink(_ app: XCUIApplication, _ element: XCUIElement, crop: (CGRect) -> CGRect) -> [Double] {
        XCTAssertTrue(element.waitForExistence(timeout: 5), app.debugDescription)
        let area = crop(element.frame)
        let window = app.windows.firstMatch.frame.width
        guard let source = XCUIScreen.main.screenshot().image.cgImage,
              let crop = source.cropping(to: area.applying(CGAffineTransform(scaleX: CGFloat(source.width) / window,
                                                                              y: CGFloat(source.width) / window))) else {
            XCTFail("No pixels for \(element)"); return [0, 0, 0]
        }
        let width = crop.width, height = crop.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            .draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        var sum = [0.0, 0.0, 0.0], count = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let rgb = [Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2])]
            guard rgb.max()! - rgb.min()! > 60 else { continue }
            for c in 0..<3 { sum[c] += Double(rgb[c]) / 255 }
            count += 1
        }
        XCTAssertGreaterThan(count, 10, "No inked pixels in \(element)")
        return sum.map { $0 / max(count, 1) }
    }

}
