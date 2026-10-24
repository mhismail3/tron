import XCTest
import UIKit

/// Samples the actual sheet's empty glass edges, not tokens or fixture probes.
/// The model card is the existing primary-surface reference; Terminal remains slate.
@MainActor final class TronManageContainerSurfaceUITests: XCTestCase {
    func testPrimaryContainersShareSurfaceAndKeepTerminalNeutral() {
        for theme in ["burgundy", "emerald", "oliveGold"] {
            for mode in ["light", "dark"] {
                let app = XCUIApplication()
                app.launchArguments = ["-tron-session-configuration-fixture", "-manage-session-review",
                    "-fixture-appearance", mode, "-themeColor", theme]
                app.launch()
                XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 10))
                app.buttons["Stop session"].tap()
                let usage = app.descendants(matching: .any)["session-usage-summary"].firstMatch
                XCTAssertTrue(usage.waitForExistence(timeout: 10))
                let title = app.navigationBars.staticTexts["Manage Session"].firstMatch
                if title.frame.minY > 120 {
                    title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
                        thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)))
                }
                let model = app.descendants(matching: .any)["session-model-summary"].firstMatch
                XCTAssertTrue(model.staticTexts["Effort"].waitForExistence(timeout: 10))
                let top = app.screenshot()
                keep(top, "manage-containers-\(theme)-\(mode)-top")
                let reference = pigment(top, app: app, frame: model.frame)
                let summary = pigment(top, app: app, frame: usage.frame)
                let workspace = app.buttons["Workspace"]
                let navigation = pigment(top, app: app, frame: workspace.frame)
                let settings = app.buttons["chat-settings-link"]
                for _ in 0..<6 where !settings.isHittable { app.swipeUp() }
                let terminal = app.buttons["manage-session-terminal"]
                for _ in 0..<6 where !terminal.isHittable { app.swipeUp() }
                let bottom = app.screenshot()
                keep(bottom, "manage-containers-\(theme)-\(mode)-bottom")
                let setting = pigment(bottom, app: app, frame: settings.frame)
                let neutral = pigment(bottom, app: app, frame: terminal.frame)
                print("MANAGE_SURFACE \(theme)-\(mode) model=\(reference) usage=\(summary) navigation=\(navigation) settings=\(setting) terminal=\(neutral)")
                if theme == "burgundy", mode == "dark" {
                    // Chroma removes neutral material brightness. The lifted ink
                    // pigment has substantially more red/green separation than wine.
                    for (name, color) in [("usage", summary), ("navigation", navigation), ("settings", setting)] {
                        XCTAssertEqual(color[0] - color[1], reference[0] - reference[1], accuracy: 5,
                            "\(name) must share the model card's deep-wine glass, not use lifted ink")
                    }
                    XCTAssertLessThan(neutral[0] - neutral[1], 3, "Terminal must keep its neutral slate treatment")
                }
                XCTAssertTrue(app.buttons["manage-session-rename"].exists)
                app.terminate()
            }
        }
    }

    private func keep(_ screenshot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func pigment(_ screenshot: XCUIScreenshot, app: XCUIApplication, frame: CGRect) -> [Double] {
        guard let image = screenshot.image.cgImage else { XCTFail("Missing native pixels"); return [0, 0, 0] }
        let scale = CGFloat(image.width) / app.windows.firstMatch.frame.width
        // A narrow, empty edge patch avoids labels, glyphs and corner highlights.
        let area = CGRect(x: frame.minX + 6, y: frame.midY - 2, width: 3, height: 4)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(area), "Surface sample must be on screen: \(area)")
        guard let crop = image.cropping(to: area.applying(CGAffineTransform(scaleX: scale, y: scale))) else {
            XCTFail("Missing surface crop"); return [0, 0, 0]
        }
        var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        let context = CGContext(data: &bytes, width: crop.width, height: crop.height, bitsPerComponent: 8,
            bytesPerRow: crop.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        return (0..<3).map { channel in
            stride(from: channel, to: bytes.count, by: 4).map { Double(bytes[$0]) }.sorted()[crop.width * crop.height / 2]
        }
    }
}
