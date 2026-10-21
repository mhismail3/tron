import XCTest

/// Samples the real rendered sheet surface, not a SwiftUI modifier or a replica.
/// The outer gutter excludes cards, title ink and glass buttons, exposing a
/// separate toolbar backdrop even when that backdrop hides from accessibility.
final class TronSheetBackgroundUITests: XCTestCase {
    @MainActor func testSheetBackgroundContinuousInLight() { journey(dark: false) }
    @MainActor func testSheetBackgroundContinuousInDark() { journey(dark: true) }

    @MainActor private func journey(dark: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-presentation-loading"]
            + (dark ? ["-home-dark"] : [])
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 15))
        app.buttons["home-pinned-row"].tap()
        let ring = app.buttons["session-context-button"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true"), object: ring)], timeout: 15), .completed)
        ring.tap()
        let manageDone = app.buttons["home-sheet-done-manage"]
        XCTAssertTrue(manageDone.waitForExistence(timeout: 5))
        assertContinuousBackground(app, done: manageDone, name: "manage-loading")
        XCTAssertTrue(app.descendants(matching: .any)["home-manage-state"].waitForExistence(timeout: 30))
        assertContinuousBackground(app, done: manageDone, name: "manage-loaded")
        app.descendants(matching: .any)["home-manage-tasks"].tap()
        let tasksDone = app.buttons["home-sheet-done-tasks"]
        XCTAssertTrue(tasksDone.waitForExistence(timeout: 5))
        assertContinuousBackground(app, done: tasksDone, name: "tasks-loading")
        XCTAssertTrue(app.buttons["home-task-active"].waitForExistence(timeout: 30))
        assertContinuousBackground(app, done: tasksDone, name: "tasks-loaded")
    }

    @MainActor private func assertContinuousBackground(_ app: XCUIApplication, done: XCUIElement, name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "1608-\(name)"; attachment.lifetime = .keepAlways; add(attachment)
        let window = app.windows.firstMatch.frame
        let toolbarY = done.frame.midY
        guard let source = screenshot.image.cgImage else { XCTFail("No screenshot pixels"); return }
        let scale = CGFloat(source.width) / window.width
        // The owned iPhone lane's medium sheet starts 8pt from the window edge;
        // x=14pt is inside its material but outside its 20pt-inset cards/buttons.
        // Compare a 2pt patch in the toolbar with the same clear gutter below it.
        let header = color(source, scale: scale, x: window.minX + 14, y: toolbarY - 8)
        let body = color(source, scale: scale, x: window.minX + 14, y: toolbarY + 72)
        for channel in 0..<3 {
            XCTAssertEqual(header[channel], body[channel], accuracy: 3,
                           "\(name): toolbar must share sheet material, not a separately revealed band: \(header) vs \(body)")
        }
    }

    private func color(_ source: CGImage, scale: CGFloat, x: CGFloat, y: CGFloat) -> [Double] {
        let area = CGRect(x: x, y: y, width: 2, height: 2)
            .applying(CGAffineTransform(scaleX: scale, y: scale))
        guard let crop = source.cropping(to: area) else { XCTFail("Patch outside screenshot"); return [0, 0, 0] }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            XCTFail("Cannot read screenshot color"); return [0, 0, 0]
        }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return pixel.prefix(3).map(Double.init)
    }
}
