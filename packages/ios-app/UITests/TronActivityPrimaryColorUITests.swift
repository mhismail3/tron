import XCTest
import UIKit

/// Rendered ink, not a reported token: the actual dashboard and composer must
/// match their primary-colored title/plus through all selectable themes.
@MainActor final class TronActivityPrimaryColorUITests: XCTestCase {
    func testActivityInkFollowsPrimaryThemeLightAndDark() {
        for theme in ["burgundy", "emerald", "oliveGold"] {
            for mode in ["light", "dark"] {
                let dashboard = XCUIApplication()
                dashboard.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready",
                    "-home-phase-active", "-home-sheet-dashboard-workers", "-dashboard-view-home",
                    "-themeColor", theme] + (mode == "dark" ? ["-home-dark"] : [])
                dashboard.launch()
                let home = dashboard.buttons["dashboard.menu"]
                let working = XCTNSPredicateExpectation(predicate:
                    NSPredicate(format: "exists == true AND value == 'Working'"), object: home)
                XCTAssertEqual(XCTWaiter.wait(for: [working], timeout: 15), .completed)
                let title = dashboard.staticTexts["Tron"].firstMatch
                XCTAssertTrue(title.exists)
                compareInk(dashboard, icon: centered(home.frame, size: 28),
                    reference: title.frame, name: "dashboard-\(theme)-\(mode)")
                dashboard.terminate()

                for state in ["active", "recent", "extension"] {
                    let composer = XCUIApplication()
                    composer.launchArguments = ["-tron-subagent-parity-fixture", "-themeColor", theme,
                        "-\(mode)", "-subagentRecentFinishedRetentionMinutes.v1", "5"]
                        + (state == "active" ? [] : ["-activity-preview-\(state)"])
                    composer.launch()
                    let orb = composer.buttons[state == "extension" ? "Extension content" : "Subagents"].firstMatch
                    XCTAssertTrue(orb.waitForExistence(timeout: 15), "Missing \(state) activity button")
                    let plus = composer.buttons["Add attachment"]
                    XCTAssertTrue(plus.exists)
                    compareInk(composer, icon: centered(orb.frame, size: 18),
                        reference: centered(plus.frame, size: 20), name: "composer-\(state)-\(theme)-\(mode)")
                    composer.terminate()
                }
            }
        }
    }

    private func centered(_ frame: CGRect, size: CGFloat) -> CGRect {
        CGRect(x: frame.midX - size / 2, y: frame.midY - size / 2, width: size, height: size)
    }

    private func compareInk(_ app: XCUIApplication, icon: CGRect, reference: CGRect, name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let image = screenshot.image.cgImage else { XCTFail("No rendered image for \(name)"); return }
        let scale = CGFloat(image.width) / app.windows.firstMatch.frame.width
        guard let actual = inkChroma(image, area: icon, scale: scale),
              let expected = inkChroma(image, area: reference, scale: scale) else {
            XCTFail("No saturated icon/reference ink in \(name)"); return
        }
        let distance = zip(actual, expected).map { abs($0 - $1) }.max()!
        print("ACTIVITY_INK \(name): icon=\(actual) primary=\(expected) distance=\(distance)")
        XCTAssertLessThan(distance, 0.15,
            "\(name): rendered activity ink \(actual) must match primary reference \(expected)")
    }

    /// Subtract the neutral channel so anti-aliasing and per-dot opacity do not
    /// change hue. Ignore low-chroma neutral glass, rather than accepting a
    /// correctly tinted container with incorrectly green glyph ink.
    private func inkChroma(_ image: CGImage, area: CGRect, scale: CGFloat) -> [Double]? {
        guard let crop = image.cropping(to: area.applying(CGAffineTransform(scaleX: scale, y: scale))) else { return nil }
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        guard let context = CGContext(data: &pixels, width: crop.width, height: crop.height, bitsPerComponent: 8,
            bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        var sum = [0.0, 0.0, 0.0]
        var count = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let rgb = [Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2])]
            let low = rgb.min()!, range = rgb.max()! - low
            guard range >= 28 else { continue }
            for c in 0..<3 { sum[c] += (rgb[c] - low) / range }
            count += 1
        }
        guard count >= 5 else { return nil }
        return sum.map { $0 / Double(count) }
    }
}
