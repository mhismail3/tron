import XCTest
import UIKit

/// Rendered color at the real chip → managed sheet → document reader boundary.
@MainActor final class TronDisplayDocumentThemeUITests: XCTestCase {
    func testRepresentativePreviews() {
        for (theme, mode, home) in [("burgundy", "dark", true), ("oliveGold", "light", false)] {
            let app = open(theme: theme, mode: mode, home: home)
            capture(app, "\(theme)-\(mode)-\(home ? "home" : "session")")
            app.terminate()
        }
    }

    func testHomeAndSessionMarkdownFollowPrimaryTheme() {
        for theme in ["burgundy", "oliveGold"] {
            for mode in ["light", "dark"] {
                for home in [true, false] {
                    let app = open(theme: theme, mode: mode, home: home)
                    let title = app.navigationBars.staticTexts[home ? "Home audit report" : "Session summary"].firstMatch
                    let link = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Navigation evidence'")).firstMatch
                    XCTAssertTrue(link.waitForExistence(timeout: 10), app.debugDescription)
                    capture(app, "regression-\(theme)-\(mode)-\(home ? "home" : "session")")
                    for (name, frame) in [("title", title.frame), ("Done", app.buttons["Done"].frame), ("Markdown link", link.frame)] {
                        let hue = chroma(app, frame)
                        if theme == "burgundy" {
                            XCTAssertGreaterThan(hue[0], hue[1] + 0.5, "\(name) must be burgundy: \(hue)")
                            XCTAssertGreaterThan(hue[0], hue[2] + 0.15, "\(name) must be burgundy: \(hue)")
                        } else {
                            XCTAssertGreaterThan(hue[0], hue[2] + 0.5, "\(name) must be olive gold: \(hue)")
                            XCTAssertGreaterThan(hue[1], hue[2] + 0.5, "\(name) must be olive gold: \(hue)")
                        }
                    }
                    app.buttons["Done"].tap()
                    XCTAssertFalse(title.exists, "Done dismisses the document")
                    app.terminate()
                }
            }
        }
    }

    private func open(theme: String, mode: String, home: Bool, html: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-chat-display-fixture", "-display-document-theme", "-themeColor", theme]
            + (mode == "light" ? ["-polish-light"] : [])
            + (home ? ["-display-document-home"] : [])
            + (html ? ["-display-document-html"] : [])
        app.launch()
        let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", home ? "Home audit report" : "Session summary")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 20), app.debugDescription)
        chip.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Navigation evidence'")).firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "2001-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func chroma(_ app: XCUIApplication, _ frame: CGRect) -> [Double] {
        let source = app.screenshot().image.cgImage!
        let scale = CGFloat(source.width) / app.windows.firstMatch.frame.width
        guard let crop = source.cropping(to: frame.applying(CGAffineTransform(scaleX: scale, y: scale))) else {
            XCTFail("No rendered area: \(frame)"); return [0, 0, 0]
        }
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        let context = CGContext(data: &pixels, width: crop.width, height: crop.height, bitsPerComponent: 8,
            bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        var sum = [0.0, 0.0, 0.0], count = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let rgb = [Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2])]
            if rgb.max()! - rgb.min()! < 45 { continue }
            for c in 0..<3 { sum[c] += rgb[c] }
            count += 1
        }
        XCTAssertGreaterThan(count, 0, "No colored ink in \(frame)")
        let low = sum.min()!, range = sum.max()! - low
        return sum.map { ($0 - low) / max(range, 1) }
    }
}
