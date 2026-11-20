import XCTest
import UIKit
import Vision

@MainActor final class TronFiveSheetPolishUITests: XCTestCase {
    func testNumericKeyboardToolbar() {
        for mode in ["light", "dark"] {
            let app = launch(mode)
            defer { app.terminate() }
            XCTAssertTrue(app.buttons["Open Settings"].waitForExistence(timeout: 10))
            app.buttons["Open Settings"].tap()
            let link = app.buttons["settings-link-Appearance"]
            reveal(link, app: app)
            link.tap()
            let field = app.textFields["Chats per project"]
            XCTAssertTrue(app.navigationBars.staticTexts["Appearance"].waitForExistence(timeout: 8), app.debugDescription)
            XCTAssertTrue(field.waitForExistence(timeout: 8), app.debugDescription)
            reveal(field, app: app)
            XCTAssertTrue(field.isHittable, app.debugDescription)
            field.tap()
            let done = app.buttons["text-entry-done"]
            XCTAssertTrue(done.waitForExistence(timeout: 5), app.debugDescription)
            shot("keyboard-\(mode)")
            assertDoneLabelIsPainted(app, done: done, mode: mode)
            let keyboard = app.keyboards.firstMatch
            XCTAssertTrue(keyboard.exists)
            XCTAssertLessThanOrEqual(done.frame.height, 44, "Keyboard toolbar must use the system control size, not the app glass target")
            XCTAssertLessThanOrEqual(done.frame.width, 100, "Done is an intrinsic toolbar item, not an expanding capsule")
            XCTAssertLessThanOrEqual(done.frame.maxY, keyboard.frame.minY + 1)
            XCTAssertGreaterThanOrEqual(done.frame.minY, keyboard.frame.minY - 60)
            done.tap()
            XCTAssertTrue(wait(keyboard, "exists == false"), "Done dismisses the number pad")
        }
    }

    private func assertDoneLabelIsPainted(_ app: XCUIApplication, done: XCUIElement, mode: String) {
        let screenshot = XCUIScreen.main.screenshot().image
        guard let image = screenshot.cgImage else { XCTFail("No actual toolbar screenshot"); return }
        let scale = CGFloat(image.width) / app.frame.width
        let region = done.frame.insetBy(dx: -6, dy: -4)
            .applying(CGAffineTransform(scaleX: scale, y: scale))
        guard let crop = image.cropping(to: region) else { XCTFail("No painted Done region"); return }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        do {
            try VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])
            let words = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let evidence = XCTAttachment(string: "Actual painted Done OCR (\(mode)): \(words)")
            evidence.name = "keyboard-label-\(mode)"; evidence.lifetime = .keepAlways; add(evidence)
            XCTAssertTrue(words.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "done" },
                          "AX can still say Done while the real label is truncated: \(words)")
        } catch { XCTFail("Could not inspect actual toolbar pixels: \(error)") }
    }

    private func launch(_ mode: String) -> XCUIApplication {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = ["-tron-mac-settings-fixture", "-themeColor", "burgundy", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-settings-nested"]
        if mode == "dark" { app.launchArguments.append("-settings-dark") }
        app.launch()
        return app
    }
    private func reveal(_ target: XCUIElement, app: XCUIApplication) {
        for _ in 0..<8 where !target.isHittable { app.swipeUp(velocity: .slow) }
    }
    private func wait(_ element: XCUIElement, _ predicate: String) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)], timeout: 8) == .completed
    }
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "five-\(name)"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
