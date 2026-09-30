import XCTest

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
            app.terminate()
        }
    }

}
