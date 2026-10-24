import XCTest
import UIKit

/// The real queue card and its editor must render the selected primary theme.
/// Native Manage Home glass is the reference for the separate surface pigment;
/// testing only ink would miss dark Burgundy's lifted-ink/deep-wine distinction.
@MainActor final class TronQueuedSteerThemeUITests: XCTestCase {
    func testQueuedCardAndEditorFollowPrimaryTheme() throws {
        for theme in ["burgundy", "emerald", "oliveGold"] {
            for mode in ["light", "dark"] {
                let app = XCUIApplication()
                app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready",
                    "-foreground-queued-editor", "-foreground-queued-steer", "-themeColor", theme]
                    + (mode == "dark" ? ["-home-dark"] : [])
                app.launch()
                defer { app.terminate() }
                let home = app.buttons["home-pinned-row"]
                guard home.waitForExistence(timeout: 15) else { XCTFail(app.debugDescription); return }
                home.tap()
                let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Queued message 1607")).firstMatch
                guard row.waitForExistence(timeout: 15) else { XCTFail(app.debugDescription); return }
                Thread.sleep(forTimeInterval: 0.6)
                let arrowButton = app.buttons["arrow.turn.up.right"].firstMatch
                XCTAssertTrue(arrowButton.waitForExistence(timeout: 5), app.debugDescription)
                let cardShot = app.screenshot()
                keep(cardShot, "queued-\(theme)-\(mode)-card")
                // AX exposes the message text, not the whole glass card. Its
                // leading padding is empty pigment, away from antialiased text.
                let fill = try pigment(cardShot, app: app, frame: row.frame, leadingInset: -6)
                assertTheme(fill, theme: theme, context: "\(mode) queued card glass")
                let arrow = try XCTUnwrap(sheetInk(cardShot.image, arrowButton.frame,
                    window: app.windows.firstMatch.frame.width), "The queue arrow must have visible accent ink")
                assertTheme(arrow, theme: theme, context: "\(mode) queued card arrow")

                row.tap()
                let editor = app.textViews["Queued message"]
                guard editor.waitForExistence(timeout: 8) else { XCTFail(app.debugDescription); return }
                XCTAssertEqual(editor.value as? String, "Queued message 1607")
                let delivery = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Delivery")).firstMatch
                XCTAssertTrue(delivery.waitForExistence(timeout: 5), app.debugDescription)
                Thread.sleep(forTimeInterval: 0.6)
                let sheetShot = app.screenshot()
                keep(sheetShot, "queued-\(theme)-\(mode)-editor")
                let surface = try pigment(sheetShot, app: app, frame: delivery.frame)
                assertTheme(surface, theme: theme, context: "\(mode) queued editor glass")
                assertToolbarTint(app, title: "Queued Message", excluding: ["Remove queued message"])
                app.buttons["Save queued message"].tap()
                XCTAssertTrue(row.waitForExistence(timeout: 5))

                let manage = app.buttons["session-context-button"]
                XCTAssertTrue(manage.waitForExistence(timeout: 5))
                manage.tap()
                let model = app.descendants(matching: .any)["home-model-summary"].firstMatch
                XCTAssertTrue(model.waitForExistence(timeout: 8), app.debugDescription)
                Thread.sleep(forTimeInterval: 0.6)
                let referenceShot = app.screenshot()
                keep(referenceShot, "queued-\(theme)-\(mode)-reference")
                let reference = try pigment(referenceShot, app: app, frame: model.frame)
                print("QUEUED_THEME \(theme)-\(mode) card=\(fill) arrow=\(arrow) sheet=\(surface) reference=\(reference)")
                if theme == "burgundy", mode == "dark" {
                    // Same native glass oracle and chroma allowance as the Manage
                    // container boundary test: ignore neutral material brightness.
                    XCTAssertEqual(surface[0] - surface[1], reference[0] - reference[1], accuracy: 5,
                        "Queued editor must share Manage Home's deep-wine surface, not lifted primary ink")
                }
                app.terminate()
            }
        }
    }

    private func assertTheme(_ color: [Double], theme: String, context: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        // Channel ordering is invariant under neutral glass blending and glyph
        // antialiasing; no golden image or brightness-sensitive color literal.
        switch theme {
        case "burgundy":
            XCTAssertGreaterThan(color[0], color[2], context, file: file, line: line)
            XCTAssertGreaterThan(color[2], color[1], context, file: file, line: line)
        case "emerald":
            XCTAssertGreaterThan(color[1], color[2], context, file: file, line: line)
            XCTAssertGreaterThan(color[2], color[0], context, file: file, line: line)
        default:
            XCTAssertGreaterThanOrEqual(color[0], color[1], context, file: file, line: line)
            XCTAssertGreaterThan(color[1], color[2], context, file: file, line: line)
        }
    }

    private func pigment(_ screenshot: XCUIScreenshot, app: XCUIApplication, frame: CGRect,
                         leadingInset: CGFloat = 6) throws -> [Double] {
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let scale = CGFloat(image.width) / app.windows.firstMatch.frame.width
        let area = CGRect(x: frame.minX + leadingInset, y: frame.midY - 2, width: 3, height: 4)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(area), "Surface sample must be visible: \(area)")
        let crop = try XCTUnwrap(image.cropping(to: area.applying(CGAffineTransform(scaleX: scale, y: scale))))
        var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: crop.width, height: crop.height,
            bitsPerComponent: 8, bytesPerRow: crop.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        return (0..<3).map { channel in
            stride(from: channel, to: bytes.count, by: 4).map { Double(bytes[$0]) }.sorted()[crop.width * crop.height / 2]
        }
    }

    private func keep(_ screenshot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
