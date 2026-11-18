import XCTest

final class TronHomeControlsUITests: XCTestCase {
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
        let controls = element(app, "home-manage-controls")
        for _ in 0..<8 where controls.exists && (!controls.isHittable || controls.frame.maxY > app.frame.maxY - 50) { app.swipeUp() }
        XCTAssertTrue(element(app, "home-manage-permissions").exists, "Task Permissions is a Manage Home row")
        XCTAssertFalse(element(app, "home-manage-pause").exists, "Pause is not a Manage Home row")
        XCTAssertFalse(element(app, "home-manage-disable").exists, "Disable is not a Manage Home row")
        let manage = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        manage.name = "manage-home-\(mode)\(accessibilityType ? "-accessibility" : "")"
        manage.lifetime = .keepAlways
        add(manage)
        open(app, controls, ready: "home-settings-controls", name: "Controls")
        return app
    }

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

    @MainActor private func open(_ app: XCUIApplication, _ row: XCUIElement, ready: String, name: String) {
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(name)\n\(app.debugDescription)")
        row.tap()
        XCTAssertTrue(element(app, ready).waitForExistence(timeout: 8), "\(ready)\n\(app.debugDescription)")
    }

    private func waitFor(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 10) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)], timeout: timeout) == .completed
    }

}
