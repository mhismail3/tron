import XCTest
import UIKit

@MainActor final class TronSixSmallUIRegressionTests: XCTestCase {
    private let root = "/Users/fixture/Workspace/tron-worktrees/six-small-ui-fixes"

    func testToastGlyphUsesActivePrimary() {
        for mode in ["light", "dark"] {
            let app = launch("toast", mode: mode)
            let card = app.staticTexts["in-app-notice-card"].firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 8))
            let title = app.staticTexts["six-ui-primary-reference"].firstMatch
            XCTAssertTrue(title.waitForExistence(timeout: 8))
            Thread.sleep(forTimeInterval: 0.7)
            let screenshot = app.screenshot()
            guard let image = screenshot.image.cgImage else { XCTFail("Missing rendered screenshot"); return }
            let scale = CGFloat(image.width) / app.windows.firstMatch.frame.width
            let slot = CGRect(x: card.frame.minX + 14, y: card.frame.minY + 8, width: 26, height: card.frame.height - 16)
            guard let actual = ink(image, slot, scale), let primary = ink(image, title.frame, scale) else {
                XCTFail("Missing visible toast glyph or primary title ink"); return
            }
            let distance = zip(actual, primary).map { abs($0 - $1) }.max()!
            print("SIX_UI_TOAST \(mode) actual=\(actual) primary=\(primary) distance=\(distance)")
            XCTAssertLessThan(distance, 0.15, "Toast icon must match the active primary theme, not hard-coded green/blue")
            attach(screenshot, "toast-primary-\(mode)")
            app.terminate()
        }
    }

    func testModelRowsShowUnprefixedIDAndKeepSearchSelection() {
        let app = launch("models")
        let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "opencode-go/deepseek-v4.1-flash"))
        let flash = rows.firstMatch
        XCTAssertTrue(flash.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertFalse(flash.label.contains("Model ID"), "The row must expose the canonical ID without a label prefix")
        XCTAssertTrue(flash.label.contains("1M context"))
        XCTAssertEqual(flash.value as? String, "Selected")
        app.buttons["Search models"].tap()
        let search = app.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("deepseek-v4-pro")
        let pro = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "opencode-go/deepseek-v4-pro")).firstMatch
        XCTAssertTrue(pro.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "opencode-go/kimi-k2.7-code")).firstMatch.exists)
        pro.tap()
        XCTAssertEqual(pro.value as? String, "Selected")
        XCTAssertTrue(app.navigationBars.staticTexts["Models"].exists, "Selection must not dismiss the picker")
        app.terminate()
    }

    func testWorkspaceNarrowAndAccessibilitySizesDoNotOverlapPath() {
        let largest = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        for extra in [["-six-ui-narrow"], ["-six-ui-narrow"] + largest,
                      [], largest] {
            let app = launch("workspace", extra: extra)
            let path = app.staticTexts[root].firstMatch
            XCTAssertTrue(path.waitForExistence(timeout: 8), app.debugDescription)
            for label in ["b8d31a1d", "Clean", "Detached HEAD"] {
                let pill = app.staticTexts[label].firstMatch
                XCTAssertTrue(pill.waitForExistence(timeout: 8), app.debugDescription)
                XCTAssertFalse(path.frame.intersects(pill.frame), "Narrow/accessibility workspace path must not overlap \(label)")
            }
            app.terminate()
        }
    }

    private func launch(_ surface: String, mode: String = "light", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-expanded-review", "-six-ui-surface", surface,
                               "-themeColor", "burgundy", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extra
        if mode == "dark" { app.launchArguments.append("-settings-renderer-dark") }
        app.launch()
        XCTAssertTrue(app.buttons["Done"].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        return app
    }

    private func attach(_ screenshot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func ink(_ image: CGImage, _ area: CGRect, _ scale: CGFloat) -> [Double]? {
        guard let crop = image.cropping(to: area.applying(CGAffineTransform(scaleX: scale, y: scale))) else { return nil }
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        guard let context = CGContext(data: &pixels, width: crop.width, height: crop.height, bitsPerComponent: 8,
            bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        var sum = [0.0, 0.0, 0.0], count = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let rgb = [Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2])]
            let low = rgb.min()!, range = rgb.max()! - low
            guard range >= 60 else { continue }
            for c in 0..<3 { sum[c] += (rgb[c] - low) / range }
            count += 1
        }
        return count >= 5 ? sum.map { $0 / Double(count) } : nil
    }
}
