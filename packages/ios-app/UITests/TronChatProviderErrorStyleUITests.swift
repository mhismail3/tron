import XCTest
import UIKit

final class TronChatProviderErrorStyleUITests: XCTestCase {
    @MainActor func testErrorPillsStayCenteredInLightAndDark() {
        continueAfterFailure = false
        for dark in [false, true] {
            let app = launch(dark: dark)
            defer { app.terminate() }
            let single = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat-error-run-")).firstMatch
            XCTAssertTrue(single.waitForExistence(timeout: 20), app.debugDescription)
            assertCenteredInk(single, in: app)
            app.buttons["Live error"].tap()
            let grouped = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Anthropic is overloaded", "2 errors")).firstMatch
            XCTAssertTrue(grouped.waitForExistence(timeout: 10), app.debugDescription)
            assertCenteredInk(grouped, in: app)
            app.buttons["Settle error"].tap()
            app.buttons["Mixed error"].tap()
            let mixed = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Provider errors")).firstMatch
            XCTAssertTrue(mixed.waitForExistence(timeout: 10), app.debugDescription)
            assertCenteredInk(mixed, in: app)
            keep(app, "centered-\(dark ? "dark" : "light")")
        }
    }

    @MainActor func testStandardErrorDetailsKeepSelectablePayload() {
        continueAfterFailure = false
        let app = launch(dark: false)
        defer { app.terminate() }
        let single = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat-error-run-")).firstMatch
        XCTAssertTrue(single.waitForExistence(timeout: 20), app.debugDescription)
        single.tap()
        let body = app.staticTexts["chat-error-body-error-first"]
        XCTAssertTrue(body.waitForExistence(timeout: 10), app.debugDescription)
        app.swipeUp()
        body.press(forDuration: 1.1)
        let copy = app.buttons["Copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10), "The standard code inset must retain native selection: \(app.debugDescription)")
        keep(app, "selectable-json")
        copy.tap()
        XCTAssertTrue(app.buttons["Done"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(single.waitForExistence(timeout: 10), "Done must return to the unchanged transcript")
    }

    /// The semantic hit target spans the transcript width, so its AX frame
    /// cannot detect left-aligned ink. Read the actual rendered error ink in
    /// that row instead; no stored pixel golden or absolute screen position.
    @MainActor private func assertCenteredInk(_ pill: XCUIElement, in app: XCUIApplication,
                                              file: StaticString = #filePath, line: UInt = #line) {
        let bounds = pill.frame.intersection(app.frame)
        guard let image = app.screenshot().image.cgImage else {
            XCTFail("Missing actual screenshot", file: file, line: line); return
        }
        let scale = CGFloat(image.width) / app.frame.width
        let rect = CGRect(x: (bounds.minX - app.frame.minX) * scale, y: (bounds.minY - app.frame.minY) * scale,
                          width: bounds.width * scale, height: bounds.height * scale).integral
        guard let crop = image.cropping(to: rect) else {
            XCTFail("Error row is outside the visible viewport", file: file, line: line); return
        }
        let w = crop.width, h = crop.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let extent: (Int, Int)? = pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
            let data = bytes.bindMemory(to: UInt8.self)
            var left = w, right = -1
            for y in 0..<h {
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    let r = Int(data[i]), g = Int(data[i + 1]), b = Int(data[i + 2])
                    if r > 120 && r > g + 35 && r > b + 35 { left = min(left, x); right = max(right, x) }
                }
            }
            return right >= left ? (left, right) : nil
        }
        guard let (left, right) = extent else {
            XCTFail("No visible error ink in the real row", file: file, line: line); return
        }
        let center = app.frame.minX + (rect.minX + CGFloat(left + right + 1) / 2) / scale
        XCTAssertEqual(center, app.frame.midX, accuracy: 4,
                       "Visible error pill must be horizontally centered, including grouped runs", file: file, line: line)
    }

    /// Actual ChatView/native sheets with synthetic Gateway facts. Capture only;
    /// this method is not behavioral acceptance or physical-device evidence.
    @MainActor func testCaptureActualErrorPresentation() {
        let phase = ProcessInfo.processInfo.environment["TRON_ERROR_PREVIEW_PHASE"] ?? "preview"
        for dark in [false, true] {
            let app = launch(dark: dark)
            let mode = dark ? "dark" : "light"
            let single = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Anthropic is overloaded")).firstMatch
            _ = single.waitForExistence(timeout: 20)
            keep(app, "\(phase)-\(mode)-single-pill")
            single.tap()
            _ = app.buttons["Done"].waitForExistence(timeout: 20)
            keep(app, "\(phase)-\(mode)-single-sheet")
            app.buttons["Done"].tap()
            app.buttons["Live error"].tap()
            let grouped = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Anthropic is overloaded", "2 errors")).firstMatch
            _ = grouped.waitForExistence(timeout: 10)
            app.buttons["Settle error"].tap()
            keep(app, "\(phase)-\(mode)-grouped-pill")
            grouped.tap()
            _ = app.buttons["Done"].waitForExistence(timeout: 20)
            app.swipeUp()
            keep(app, "\(phase)-\(mode)-grouped-sheet")
            app.buttons["Done"].tap()
            app.buttons["Mixed error"].tap()
            let mixed = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Provider errors")).firstMatch
            _ = mixed.waitForExistence(timeout: 10)
            keep(app, "\(phase)-\(mode)-mixed-pill")
            mixed.tap()
            _ = app.buttons["Done"].waitForExistence(timeout: 20)
            keep(app, "\(phase)-\(mode)-mixed-sheet")
            app.swipeUp()
            keep(app, "\(phase)-\(mode)-mixed-details")
            app.terminate()
        }
    }

    @MainActor private func launch(dark: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-chat-haptics-fixture", "-chat-provider-errors", "-error-style-preview",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if dark { app.launchArguments.append("-error-preview-dark") }
        app.launch()
        return app
    }

    @MainActor private func keep(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "1993-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
