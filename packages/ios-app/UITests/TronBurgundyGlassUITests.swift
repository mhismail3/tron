import XCTest
import UIKit

/// The canonical wine surface must not wash out small primary ink. Read actual
/// native pixels through Home -> Manage Home -> Home Settings, not token probes.
@MainActor final class TronBurgundyGlassUITests: XCTestCase {
    func testWineGlassKeepsInkReadableAndLightBurgundyUnchanged() {
        continueAfterFailure = false
        for mode in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-phase-active",
                "-home-sheet-dashboard-workers", "-dashboard-view-home", "-settings-scope-review",
                "-themeColor", "burgundy"] + (mode == "dark" ? ["-home-dark"] : [])
            app.launch()
            defer { app.terminate() }
            let card = app.buttons["home-usage-card"]
            XCTAssertTrue(card.waitForExistence(timeout: 15), app.debugDescription)
            let frame = card.frame
            check(app, ink: CGRect(x: frame.minX + frame.width * 0.48, y: frame.minY + frame.height * 0.08,
                                   width: frame.width * 0.49, height: frame.height * 0.24),
                  background: CGRect(x: frame.minX + frame.width * 0.40, y: frame.minY + frame.height * 0.18,
                                     width: 4, height: 4), mode: mode, name: "Home usage")

            app.buttons["dashboard.menu"].tap()
            let manage = app.buttons["session-context-button"]
            XCTAssertTrue(manage.waitForExistence(timeout: 15)); manage.tap()
            XCTAssertTrue(app.descendants(matching: .any)["home-manage-state"].firstMatch.waitForExistence(timeout: 10))
            expand(app, title: "Manage Home")
            app.buttons["home-manage-settings"].tap()
            let models = app.buttons["settings-section-model-open"]
            XCTAssertTrue(models.waitForExistence(timeout: 10))
            expand(app, title: "Home Settings")
            let row = models.frame
            check(app, ink: CGRect(x: row.minX, y: row.midY - 12, width: 30, height: 24),
                  background: CGRect(x: row.maxX - 20, y: row.midY - 2, width: 4, height: 4),
                  mode: mode, name: "Inherited Home Settings")
        }
    }

    private func expand(_ app: XCUIApplication, title: String) {
        let label = app.navigationBars.staticTexts[title].firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 10))
        if label.frame.minY > 120 {
            label.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
                thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)))
        }
    }

    private func check(_ app: XCUIApplication, ink: CGRect, background: CGRect, mode: String, name: String) {
        let screenshot = app.screenshot()
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = "\(name)-\(mode)"; shot.lifetime = .keepAlways; add(shot)
        let image = screenshot.image.cgImage!
        let scale = CGFloat(image.width) / app.windows.firstMatch.frame.width
        let saturated = pixels(image, ink, scale).filter { $0.max()! - $0.min()! >= 28 }
            .sorted { ($0.max()! - $0.min()!) > ($1.max()! - $1.min()!) }
        XCTAssertGreaterThanOrEqual(saturated.count, 32, "Missing rendered primary ink: \(name)")
        let selected = Array(saturated.prefix(32))
        let foreground = (0..<3).map { c in selected.map { $0[c] }.reduce(0, +) / Double(selected.count) }
        let patch = pixels(image, background, scale)
        let backdrop = (0..<3).map { c in patch.map { $0[c] }.sorted()[patch.count / 2] }
        let a = luminance(foreground), b = luminance(backdrop)
        let contrast = (max(a, b) + 0.05) / (min(a, b) + 0.05)
        print("WINE_GLASS \(name)-\(mode) ink=\(foreground) background=\(backdrop) contrast=\(contrast)")
        XCTAssertGreaterThanOrEqual(contrast, 4.5, "\(name) primary ink must remain readable on actual glass")
        if mode == "dark" {
            // The approved surface is red-violet wine, not the old near-red
            // salmon tint. Normalize away material brightness/opacity.
            let wineHue = (backdrop[2] - backdrop[1]) / max(backdrop[0] - backdrop[1], 1)
            XCTAssertGreaterThanOrEqual(wineHue, 0.30, "Dark glass must use the wine surface role, not lifted salmon ink")
            XCTAssertLessThan(wineHue, 0.80, "Wine glass must stay red-dominant, not turn violet")
        } else {
            let unchanged = [87.0, 21.0, 47.0] // Approved light #57152F, observed through native pixels.
            XCTAssertLessThan(zip(foreground, unchanged).map { abs($0 - $1) }.max()!, 8,
                              "Light Burgundy must not change while refining dark mode")
        }
    }

    private func pixels(_ image: CGImage, _ area: CGRect, _ scale: CGFloat) -> [[Double]] {
        let crop = image.cropping(to: area.applying(CGAffineTransform(scaleX: scale, y: scale)))!
        var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        let context = CGContext(data: &bytes, width: crop.width, height: crop.height, bitsPerComponent: 8,
            bytesPerRow: crop.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        return stride(from: 0, to: bytes.count, by: 4).map { [Double(bytes[$0]), Double(bytes[$0 + 1]), Double(bytes[$0 + 2])] }
    }

    private func luminance(_ rgb: [Double]) -> Double {
        zip(rgb, [0.2126, 0.7152, 0.0722]).reduce(0) { sum, pair in
            let value = pair.0 / 255
            return sum + (value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)) * pair.1
        }
    }
}
