import XCTest
import UIKit

/// Real SwiftUI usage, attributed instructions and history ink compared with
/// each sheet's primary title. Attachments are native simulator approval proofs,
/// not goldens. Emerald and the two non-green themes exercise the same owners.
@MainActor final class TronSharedPrimaryAccentsUITests: XCTestCase {
    func testBurgundyLight() { journey(theme: "burgundy", mode: "light") }
    func testBurgundyDark() { journey(theme: "burgundy", mode: "dark") }
    func testEmeraldLight() { journey(theme: "emerald", mode: "light") }
    func testEmeraldDark() { journey(theme: "emerald", mode: "dark") }
    func testOliveGoldLight() { journey(theme: "oliveGold", mode: "light") }
    func testOliveGoldDark() { journey(theme: "oliveGold", mode: "dark") }

    private func journey(theme: String, mode: String) {
        let session = XCUIApplication()
        session.launchArguments = ["-tron-session-configuration-fixture", "-manage-session-review", "-history-large",
            "-fixture-appearance", mode, "-themeColor", theme]
        session.launch()
        XCTAssertTrue(session.buttons["Stop session"].waitForExistence(timeout: 10))
        session.buttons["Stop session"].tap()
        expand(session, title: "Manage Session")
        let progress = session.progressIndicators["Context used"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 8), session.debugDescription)
        XCTAssertEqual(progress.value as? String, "31 percent")
        verify(session, areas: [progress.frame], title: "Manage Session", name: "\(theme)-\(mode)-usage")
        let history = session.buttons["Session History"]
        for _ in 0..<8 where !history.isHittable { session.swipeUp() }
        XCTAssertTrue(history.isHittable, session.debugDescription)
        history.tap()
        expand(session, title: "Session History")
        let current = element(session, "history-row-h-6732-status")
        let response = element(session, "history-row-h-6731-leading")
        XCTAssertTrue(current.waitForExistence(timeout: 8), session.debugDescription)
        XCTAssertTrue(response.exists, session.debugDescription)
        verify(session, areas: [element(session, "history-row-h-6732-leading").frame, current.frame, response.frame],
            title: "Session History", name: "\(theme)-\(mode)-history")
        session.terminate()

        let instructions = XCUIApplication()
        instructions.launchArguments = ["-tron-agent-instructions-fixture", "-themeColor", theme]
            + (mode == "dark" ? ["-home-dark"] : [])
        instructions.launch()
        XCTAssertTrue(instructions.buttons["agent-instructions-section-tools"].waitForExistence(timeout: 10))
        expand(instructions, title: "Instructions")
        for (section, indices) in [("tools", [0, 1]), ("rules", [0, 2]), ("skills", [0])] {
            let row = instructions.buttons["agent-instructions-section-\(section)"]
            for _ in 0..<6 where !row.isHittable { instructions.swipeUp() }
            XCTAssertTrue(row.isHittable, instructions.debugDescription)
            row.tap()
            let title = section.capitalized
            expand(instructions, title: title)
            let areas = indices.map { index -> CGRect in
                let entry = element(instructions, "agent-instructions-entry-\(section).\(index)")
                XCTAssertTrue(entry.waitForExistence(timeout: 8), instructions.debugDescription)
                // Source capsules own the trailing edge of the shared settings
                // row; the leading glyph is themed independently by that row.
                return CGRect(x: entry.frame.maxX - 70, y: entry.frame.minY,
                              width: 70, height: entry.frame.height)
            }
            verify(instructions, areas: areas, title: title, name: "\(theme)-\(mode)-\(section)")
            instructions.navigationBars.containing(.staticText, identifier: title).buttons["Done"].firstMatch.tap()
        }
        instructions.terminate()
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func expand(_ app: XCUIApplication, title text: String) {
        let title = app.navigationBars.staticTexts[text].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 8), app.debugDescription)
        if title.frame.minY > 120 {
            title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
                thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)))
        }
        Thread.sleep(forTimeInterval: 0.6)
    }

    private func verify(_ app: XCUIApplication, areas: [CGRect], title: String, name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        guard let image = screenshot.image.cgImage else { XCTFail("Missing screenshot"); return }
        let scale = CGFloat(image.width) / app.windows.firstMatch.frame.width
        let titleFrame = app.navigationBars.staticTexts[title].firstMatch.frame
        guard let expected = ink(image, area: titleFrame, scale: scale) else {
            XCTFail("Missing primary title ink: \(name)"); return
        }
        for (index, area) in areas.enumerated() {
            guard let actual = ink(image, area: area, scale: scale) else {
                XCTFail("Missing rendered accent: \(name) area \(index) \(area)"); continue
            }
            let distance = zip(actual, expected).map { abs($0 - $1) }.max()!
            print("SHARED_PRIMARY \(name)[\(index)] actual=\(actual) primary=\(expected) distance=\(distance)")
            XCTAssertLessThan(distance, 0.15, "\(name)[\(index)] must match rendered primary title ink")
        }
    }

    /// Remove neutral glass and normalize chroma to compare hue independently
    /// of antialiasing and opacity. Does not accept a tinted container as proof
    /// when its glyph retains a different hue.
    private func ink(_ image: CGImage, area: CGRect, scale: CGFloat) -> [Double]? {
        guard let crop = image.cropping(to: area.applying(CGAffineTransform(scaleX: scale, y: scale))) else { return nil }
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        guard let context = CGContext(data: &pixels, width: crop.width, height: crop.height, bitsPerComponent: 8,
            bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        var sum = [0.0, 0.0, 0.0], count = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let rgb = [Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2])]
            let low = rgb.min()!, range = rgb.max()! - low
            guard range >= 28 else { continue }
            for c in 0..<3 { sum[c] += (rgb[c] - low) / range }
            count += 1
        }
        return count >= 5 ? sum.map { $0 / Double(count) } : nil
    }
}
