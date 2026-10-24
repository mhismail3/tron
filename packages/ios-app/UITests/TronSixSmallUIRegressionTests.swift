import XCTest
import UIKit

/// Production SwiftUI over the hosted Gateway socket. No golden/source assertions.
@MainActor final class TronSixSmallUIRegressionTests: XCTestCase {
    private let root = "/Users/fixture/Workspace/tron-worktrees/six-small-ui-fixes"

    func testHomeSettingsOrder() {
        for mode in ["light", "dark"] {
            let app = launch("home", mode: mode)
            ordered(app, ["Models", "Tools", "More Settings"])
            app.terminate()
        }
    }

    func testSessionSettingsOrder() {
        for mode in ["light", "dark"] {
            let app = launch("session", mode: mode)
            ordered(app, ["Compaction", "Tools", "Project Trust", "More Settings"])
            app.terminate()
        }
    }

    func testToastGlyphUsesActivePrimary() {
        for mode in ["light", "dark"] {
            let app = launch("toast", mode: mode)
            let card = app.staticTexts["in-app-notice-card"].firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 8))
            // A notice correctly covers the navigation title; use visible primary ink below it.
            let title = app.staticTexts["six-ui-primary-reference"].firstMatch
            XCTAssertTrue(title.waitForExistence(timeout: 8))
            Thread.sleep(forTimeInterval: 0.7)
            let screenshot = app.screenshot()
            guard let image = screenshot.image.cgImage else { XCTFail("Missing rendered screenshot"); return }
            let scale = CGFloat(image.width) / app.windows.firstMatch.frame.width
            // Sample only the icon slot, not the glass tint or neutral message.
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

    func testModelRowUsesSharedSubtextAndMonospacedID() {
        let app = launch("models", extra: ["-six-ui-typography"])
        for slot in ["subtext", "metadata"] {
            let actual = app.descendants(matching: .any)["model-picker-row-opencode-go/deepseek-v4-pro-\(slot)"].firstMatch
            let reference = app.descendants(matching: .any)["six-ui-row-reference-\(slot)"].firstMatch
            XCTAssertTrue(actual.waitForExistence(timeout: 8), app.debugDescription)
            XCTAssertTrue(reference.exists)
            XCTAssertEqual(actual.frame.height, reference.frame.height, accuracy: 0.5, "Catalog \(slot) must use the shared row's type metrics")
            XCTAssertEqual(actual.frame.width, reference.frame.width, accuracy: 0.5, "ID glyph advances must match the shared monospaced reference")
        }
        app.terminate()
    }

    func testWorkspacePathNeverIntersectsStatusPills() {
        for extra in [[], ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]] {
            let app = launch("workspace", extra: extra)
            let path = app.staticTexts[root].firstMatch
            XCTAssertTrue(path.waitForExistence(timeout: 8), app.debugDescription)
            for label in ["b8d31a1d", "Clean", "Detached HEAD"] {
                let pill = app.staticTexts[label].firstMatch
                XCTAssertTrue(pill.waitForExistence(timeout: 8), app.debugDescription)
                XCTAssertFalse(path.frame.intersects(pill.frame), "Workspace path \(path.frame) overlaps \(label) \(pill.frame)")
            }
            attach(app.screenshot(), "workspace-no-overlap-\(extra.isEmpty ? "standard" : "accessibility")")
            app.terminate()
        }
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

    func testCheckinShowsSummaryProgressAttentionAndTimestamp() {
        for blocked in [false, true] {
            let app = launch(blocked ? "checkin-blocked" : "checkin")
            let summary = app.staticTexts["Landed with explicit validation deferral"].firstMatch
            XCTAssertTrue(summary.waitForExistence(timeout: 8), app.debugDescription)
            for text in ["Attention", "Needs attention", "Done", "Next", "Timestamp"] {
                let row = app.descendants(matching: .any)["home-tool-row-\(text)"].firstMatch
                for _ in 0..<4 where !row.isHittable { app.swipeUp() }
                XCTAssertTrue(row.exists, "Checkin needs a readable \(text) row: \(app.debugDescription)")
            }
            if blocked {
                XCTAssertTrue(app.descendants(matching: .any)["home-tool-row-Blocker"].firstMatch.exists)
            }
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Checkin Object")).firstMatch.exists)
            app.terminate()
        }
    }

    func testCheckinValuesMatchCanonicalReceipt() {
        for blocked in [false, true] {
            let app = launch(blocked ? "checkin-blocked" : "checkin")
            let expected = [
                ("Attention", blocked ? "Requested" : "None"),
                ("Needs attention", blocked ? "Yes" : "No"),
                ("Done", "Prepared the six UI changes and captured light and dark simulator previews."),
                ("Next", "Review the previews, then run focused UI regressions after approval."),
                ("Timestamp", "2026")
            ] + (blocked ? [("Blocker", "Visual approval is needed before testing and landing.")] : [])
            for (title, value) in expected {
                let row = app.descendants(matching: .any)["home-tool-row-\(title)"].firstMatch
                guard row.waitForExistence(timeout: 8) else {
                    XCTFail("Missing readable check-in receipt field: \(title)"); app.terminate(); return
                }
                for _ in 0..<4 where !row.isHittable { app.swipeUp() }
                XCTAssertTrue(row.label.contains(value), "\(title) must preserve receipt value: \(row.label)")
            }
            app.terminate()
        }
    }

    private func ordered(_ app: XCUIApplication, _ titles: [String]) {
        var previous: XCUIElement?
        for title in titles {
            let row = app.buttons[title].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 8), app.debugDescription)
            if let previous { XCTAssertLessThan(previous.frame.midY, row.frame.midY, "\(previous.label) must precede \(title)") }
            previous = row
        }
        attach(app.screenshot(), "settings-order")
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
