import XCTest
import UIKit

/// Real transcript DTOs pass through the mounted ChatView and its compact chips.
/// Chip color is observed from rendered title ink: the message category owns
/// the color, never the producer's origin kind.
@MainActor final class TronChatChipCategoryColorUITests: XCTestCase {
    private struct Ink { let light: String; let dark: String }

    /// Title ink per chip category, keyed by the chip's rendered title.
    /// Tools and own-session chrome use the selected theme's ink.
    private static let burgundy = Ink(light: "#57152F", dark: "#B6478C")
    private static let expected: [(category: String, title: String, ink: Ink)] = [
        ("tool", "Read file", burgundy),
        ("running", "Run command", Ink(light: "#92400E", dark: "#FBBF24")),
        ("failed", "Search text", Ink(light: "#DC2626", dark: "#EF4444")),
        ("automation", "Automation · Daily digest", Ink(light: "#1F6675", dark: "#8BD8E4")),
        ("worker", "Worker · Fix typo", Ink(light: "#2F4C63", dark: "#A9C4D8")),
        ("subagent", "Subagent", Ink(light: "#006657", dark: "#5DE0CE")),
        ("notification", "Indexer · Notification", Ink(light: "#0369A1", dark: "#38BDF8")),
        ("command", "Reviewer · /review", Ink(light: "#4338CA", dark: "#C7D2FE")),
        ("prompt", "Code Review", Ink(light: "#4338CA", dark: "#C7D2FE")),
        ("context", "Fixture extension · Context", Ink(light: "#475569", dark: "#CBD5E1")),
        ("model", "Model changed", burgundy),
        ("compaction", "Context compacted", burgundy),
    ]

    func testChipInkFollowsMessageCategory() {
        for mode in ["light", "dark"] {
            let app = launch(theme: "burgundy", mode: mode)
            let screenshot = app.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "chat-chip-ink-\(mode)"; attachment.lifetime = .keepAlways; add(attachment)
            guard let image = screenshot.image.cgImage else { XCTFail("No native screenshot"); return }
            let scale = CGFloat(image.width) / app.windows.firstMatch.frame.width
            for row in Self.expected {
                let title = app.staticTexts[row.title].firstMatch
                XCTAssertTrue(title.exists, "\(row.category): missing chip title '\(row.title)'")
                guard title.exists, let ink = coreInk(image, title.frame, scale: scale) else {
                    XCTFail("\(row.category) \(mode): no measurable title ink"); continue
                }
                let target = rgb(mode == "light" ? row.ink.light : row.ink.dark)
                let distance = zip(ink, target).map { ($0 - $1) * ($0 - $1) }.reduce(0, +).squareRoot()
                print("CHIP_INK \(mode) \(row.category) measured \(ink.map { Int($0) }) target \(target.map { Int($0) }) distance \(Int(distance))")
                XCTAssertLessThan(distance, 16, "\(row.category) \(mode): title ink \(ink.map { Int($0) }) is not \(mode == "light" ? row.ink.light : row.ink.dark)")
            }
            app.terminate()
        }
    }

    private func launch(theme: String, mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-subagent-parity-fixture", "-chat-chip-categories", "-\(mode)",
                               "-themeColor", theme, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Automation · Daily digest"].waitForExistence(timeout: 12), app.debugDescription)
        return app
    }

    /// The text's fully covered glyph pixels: those farthest from the chip
    /// surface. Anti-aliased edges blend with the surface and are excluded.
    private func coreInk(_ image: CGImage, _ frame: CGRect, scale: CGFloat) -> [Double]? {
        let rect = frame.insetBy(dx: 0, dy: 2).applying(CGAffineTransform(scaleX: scale, y: scale)).integral
        guard let crop = image.cropping(to: rect) else { return nil }
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        guard let context = CGContext(data: &pixels, width: crop.width, height: crop.height, bitsPerComponent: 8,
            bytesPerRow: crop.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        let colors = stride(from: 0, to: pixels.count, by: 4).map { index in
            (0..<3).map { Double(pixels[index + $0]) }
        }
        var counts: [[Int]: Int] = [:]
        for color in colors { counts[color.map { Int($0) / 8 }, default: 0] += 1 }
        guard let surfaceKey = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        let surface = surfaceKey.map { Double($0 * 8 + 4) }
        let distances = colors.map { zip($0, surface).map { ($0 - $1) * ($0 - $1) }.reduce(0, +).squareRoot() }
        guard let farthest = distances.max(), farthest > 40 else { return nil }
        let core = zip(colors, distances).filter { $0.1 >= farthest * 0.85 }.map(\.0)
        guard core.count >= 12 else { return nil }
        return (0..<3).map { channel in core.map { $0[channel] }.reduce(0, +) / Double(core.count) }
    }

    private func rgb(_ hex: String) -> [Double] {
        let value = Int(hex.dropFirst(), radix: 16)!
        return [Double((value >> 16) & 0xFF), Double((value >> 8) & 0xFF), Double(value & 0xFF)]
    }
}
