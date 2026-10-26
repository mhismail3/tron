import XCTest
import UIKit

/// Gateway transcript DTOs pass through the real mounted ChatView/projector and
/// native chip. Color is observed from rendered title ink, not a policy probe.
@MainActor final class TronToolSummaryTintUITests: XCTestCase {
    func testCaptureForVisualApproval() {
        for mode in ["light", "dark"] {
            for scenario in ["recovered", "latest-failed"] {
                let (app, _) = launch(scenario, mode: mode)
                capture(app, "\(scenario)-\(mode)")
                app.terminate()
            }
        }
    }

    func testRestingTintFollowsCanonicalLatestInvocation() {
        continueAfterFailure = false
        for mode in ["light", "dark"] {
            for scenario in ["recovered", "latest-failed", "clean", "cross-group"] {
                let (app, chip) = launch(scenario, mode: mode)
                XCTAssertEqual(chip.label, scenario == "clean" ? "3 tools, Completed, 7.5s" : "3 tools, 1 failed, 7.5s")
                verifyInk(app, chip: chip, expected: scenario == "latest-failed" ? .error : .tool,
                          name: "\(scenario)-\(mode)")
                // The actual chip still opens its aggregate sheet; counts and
                // individual failed/successful tool results remain reachable.
                chip.tap()
                XCTAssertTrue(app.buttons["Done"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
                let latest = app.descendants(matching: .any)["tool-run-summary-tint-\(scenario)-2"].firstMatch
                XCTAssertTrue(latest.exists, app.debugDescription)
                XCTAssertTrue(latest.label.contains(scenario == "latest-failed" ? "Failed" : "Completed"), latest.label)
                app.terminate()
            }
        }
    }

    func testActiveTintAndProgressArePreserved() {
        continueAfterFailure = false
        for scenario in ["active-clean", "active-failed"] {
            let (app, chip) = launch(scenario, mode: "dark")
            XCTAssertTrue(chip.label.contains(scenario == "active-failed" ? "1 failed" : "In progress"), chip.label)
            verifyInk(app, chip: chip, expected: scenario == "active-failed" ? .error : .warning, name: scenario)
            chip.tap()
            XCTAssertTrue(app.buttons["Done"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
            let latest = app.descendants(matching: .any)["tool-run-summary-tint-\(scenario)-2"].firstMatch
            XCTAssertTrue(latest.exists, app.debugDescription)
            XCTAssertTrue(latest.label.contains("Invocation"), latest.label)
            app.terminate()
        }
    }

    private enum Ink { case tool, error, warning }

    private func launch(_ scenario: String, mode: String) -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-subagent-parity-fixture", "-tool-summary-tint", scenario,
                               "-\(mode)", "-themeColor", "emerald", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Tool summary review · \(scenario)"].waitForExistence(timeout: 12), app.debugDescription)
        let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '3 tools,'")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 5), app.debugDescription)
        return (app, chip)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    private func verifyInk(_ app: XCUIApplication, chip: XCUIElement, expected: Ink, name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        guard let image = screenshot.image.cgImage else { XCTFail("No native screenshot"); return }
        let scale = CGFloat(image.width) / app.windows.firstMatch.frame.width
        // Sample the '3 tools' foreground only, excluding the deliberately
        // unchanged aggregate-error icon and the duration/detail labels.
        let title = CGRect(x: chip.frame.minX + 28, y: chip.frame.midY - 9, width: 54, height: 18)
        guard let crop = image.cropping(to: title.applying(CGAffineTransform(scaleX: scale, y: scale))) else {
            XCTFail("No title crop"); return
        }
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        guard let context = CGContext(data: &pixels, width: crop.width, height: crop.height, bitsPerComponent: 8,
            bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { XCTFail("No pixel context"); return }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        var sum = [0.0, 0.0, 0.0], count = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let rgb = (0..<3).map { Double(pixels[index + $0]) }
            let low = rgb.min()!, range = rgb.max()! - low
            guard range >= 60 else { continue }
            for channel in 0..<3 { sum[channel] += (rgb[channel] - low) / range }
            count += 1
        }
        XCTAssertGreaterThan(count, 20, "Must observe actual colored title ink")
        guard count > 0 else { return }
        let ink = sum.map { $0 / Double(count) }
        print("TOOL_SUMMARY_INK \(name) \(ink)")
        switch expected {
        case .tool:
            XCTAssertGreaterThan(ink[1], 0.8, "\(name): default tool ink must be green")
            XCTAssertLessThan(ink[0], 0.4, "\(name): historical failure must not leave resting title red")
        case .error:
            XCTAssertGreaterThan(ink[0], 0.8, "\(name): latest failure retains red")
            XCTAssertLessThan(ink[1], 0.25, "\(name): red, not active amber")
        case .warning:
            XCTAssertGreaterThan(ink[0], 0.8, "\(name): active amber")
            XCTAssertGreaterThan(ink[1], 0.4, "\(name): active amber, not error red")
        }
    }
}
