import XCTest
import UIKit

@MainActor
final class TronChatDisplayUITests: XCTestCase {
    private func launch(_ orientation: String, accessories: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-chat-display-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if accessories { app.launchArguments.append("-fixture-accessories") }
        app.launchEnvironment["TRON_CHAT_TRANSCRIPT_ORIENTATION"] = orientation
        app.launch()
        XCTAssertTrue(app.buttons["Open Orientation Image photo preview"].waitForExistence(timeout: 15), app.debugDescription)
        return app
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        assertUprightImagePixels(attachmentName: name)
    }

    /// Inspect actual compositor pixels: the old origin menu had no colored
    /// preview at all even though its AX buttons and delegate were reachable.
    private func assertUprightImagePixels(attachmentName: String) {
        guard let image = XCUIScreen.main.screenshot().image.cgImage else { return XCTFail("Missing screenshot") }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return XCTFail("Missing pixel context") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var redY = 0, blueY = 0, redCount = 0, blueCount = 0
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if bytes[i] > 160 && bytes[i + 1] < 70 && bytes[i + 2] < 70 { redY += y; redCount += 1 }
                if bytes[i + 2] > 160 && bytes[i] < 70 && bytes[i + 1] < 70 { blueY += y; blueCount += 1 }
            }
        }
        XCTAssertGreaterThan(redCount, 500, "\(attachmentName): real card must remain visible")
        XCTAssertGreaterThan(blueCount, 500, "\(attachmentName): real card must remain visible")
        if redCount > 0 && blueCount > 0 {
            XCTAssertLessThan(Double(redY) / Double(redCount), Double(blueY) / Double(blueCount), attachmentName)
        }
    }

    func testInlineImageMenuLiftAndDismiss() {
        for orientation in ["end", "origin"] {
            let app = launch(orientation)
            let image = app.buttons["Open Orientation Image photo preview"]
            let badge = app.buttons["Collapse Orientation Image"]
            XCTAssertTrue(badge.waitForExistence(timeout: 5))
            let original = image.frame
            capture("\(orientation)-image-at-rest")
            XCTAssertLessThan(badge.frame.midY, original.midY, "Close badge must be at visual top")
            XCTAssertGreaterThan(badge.frame.midX, original.midX)
            image.press(forDuration: 1)
            XCTAssertTrue(app.buttons["Tool Details"].waitForExistence(timeout: 5), app.debugDescription)
            capture("\(orientation)-image-mid-menu")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
            XCTAssertTrue(image.waitForExistence(timeout: 5))
            capture("\(orientation)-image-after-dismiss")
            XCTAssertEqual(image.frame.midX, original.midX, accuracy: 0.5)
            XCTAssertEqual(image.frame.midY, original.midY, accuracy: 0.5)
            XCTAssertLessThan(badge.frame.midY, image.frame.midY)
            let scroll = app.scrollViews.allElementsBoundByIndex.first {
                $0.frame.width > app.frame.width * 0.9 && $0.frame.height > app.frame.height * 0.5
            }!
            scroll.swipeDown(velocity: .fast)
            scroll.swipeDown(velocity: .fast)
            XCTAssertFalse(image.isHittable, "Exercise offscreen lazy history, not only the original mount")
            for _ in 0..<4 where !image.isHittable { scroll.swipeUp(velocity: .fast) }
            XCTAssertTrue(image.isHittable)
            capture("\(orientation)-image-after-lazy-return")
            XCTAssertLessThan(badge.frame.midY, image.frame.midY)
            app.terminate()
        }
    }

}
