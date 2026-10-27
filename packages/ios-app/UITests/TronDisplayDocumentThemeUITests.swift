import XCTest
import UIKit

/// Rendered color at the real chip → managed sheet → document reader boundary.
@MainActor final class TronDisplayDocumentThemeUITests: XCTestCase {
    func testSiblingMarkdownImageAndUnavailableTargets() {
        continueAfterFailure = false
        for mode in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-chat-display-fixture", "-display-document-theme", "-display-document-images",
                                   "-display-document-home", "-themeColor", "burgundy"]
                + (mode == "light" ? ["-polish-light"] : [])
            app.launch()
            defer { app.terminate() }
            let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Home audit report")).firstMatch
            XCTAssertTrue(chip.waitForExistence(timeout: 20), app.debugDescription)
            chip.tap()
            let image = app.images["Preview"].firstMatch
            XCTAssertTrue(image.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertGreaterThan(image.frame.width, 100, "Sibling capture is readable, not an icon")
            let frame = image.frame.insetBy(dx: 8, dy: 8)
            let top = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 3)
            let bottom = CGRect(x: frame.minX, y: frame.maxY - frame.height / 3, width: frame.width, height: frame.height / 3)
            let red = chroma(app, top), blue = chroma(app, bottom)
            XCTAssertGreaterThan(red[0], red[2] + 0.5, "Actual sibling PNG pixels render red above blue")
            XCTAssertGreaterThan(blue[2], blue[0] + 0.5, "Actual sibling PNG pixels render red above blue")
            XCTAssertTrue(app.staticTexts["Missing: image unavailable."].firstMatch.exists, app.debugDescription)
            XCTAssertTrue(app.staticTexts["Outside: image unavailable."].firstMatch.exists, app.debugDescription)
            capture(app, "2027-markdown-images-\(mode)")
            app.buttons["Done"].tap()
            XCTAssertTrue(chip.isHittable, "The reader remains dismissible")
            app.terminate()
        }
    }

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

    func testMountedReaderUpdatesThemeAndAppearance() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-chat-display-fixture", "-display-document-updates", "-themeColor", "burgundy"]
        app.launch()
        defer { app.terminate() }
        let open = app.buttons["Open theme-change reader"]
        XCTAssertTrue(open.waitForExistence(timeout: 15)); open.tap()
        let link = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Navigation evidence'")).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        let title = app.navigationBars.staticTexts["Theme change reader"].firstMatch
        let originalFrame = link.frame
        for olive in [false, true] {
            if olive { app.buttons["Switch reader theme"].tap() }
            for appearanceChange in [false, true] {
                if appearanceChange { app.buttons["Switch reader appearance"].tap() }
                for frame in [title.frame, app.buttons["Done"].frame, link.frame] {
                    let hue = chroma(app, frame)
                    XCTAssertGreaterThan(hue[0], hue[2] + (olive ? 0.5 : 0.15), "Mounted reader adopts the new theme: \(hue)")
                    if olive { XCTAssertGreaterThan(hue[1], hue[2] + 0.5) }
                    else { XCTAssertGreaterThan(hue[0], hue[1] + 0.5) }
                }
                XCTAssertEqual(link.frame.minY, originalFrame.minY, accuracy: 1, "Theme changes preserve reader layout")
            }
        }
        capture(app, "mounted-reader-theme-appearance-updated")
        app.buttons["Done"].tap()
        XCTAssertTrue(open.isHittable, "The same sheet remains dismissible")
    }

    func testAuthoredHTMLKeepsLinkWarningAndErrorColors() {
        for mode in ["light", "dark"] {
            let app = open(theme: "burgundy", mode: mode, home: true, html: true)
            defer { app.terminate() }
            let link = app.links["Authored cyan link"].firstMatch
            XCTAssertTrue(link.waitForExistence(timeout: 10), app.debugDescription)
            let cyan = chroma(app, link.frame)
            XCTAssertGreaterThan(cyan[1], cyan[0] + 0.5)
            XCTAssertGreaterThan(cyan[2], cyan[0] + 0.5)
            for label in ["Semantic warning", "Semantic error"] {
                let text = app.staticTexts[label].firstMatch
                XCTAssertTrue(text.exists, app.debugDescription)
                let hue = chroma(app, text.frame)
                XCTAssertGreaterThan(hue[0], hue[1] + 0.5, "Authored semantic ink remains red/orange: \(hue)")
                XCTAssertGreaterThan(hue[0], hue[2] + 0.5)
            }
            let title = app.navigationBars.staticTexts["Home audit report"].firstMatch
            let hue = chroma(app, title.frame)
            XCTAssertGreaterThan(hue[0], hue[1] + 0.5, "Only native HTML sheet chrome is themed")
            capture(app, "authored-html-\(mode)")
            app.buttons["Done"].tap()
            app.terminate()
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
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", html ? "Authored document" : "Navigation evidence")).firstMatch.waitForExistence(timeout: 10), app.debugDescription)
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
