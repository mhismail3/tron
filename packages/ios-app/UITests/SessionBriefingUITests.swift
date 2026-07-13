import XCTest

final class SessionBriefingUITests: XCTestCase {
    @MainActor
    func testSessionBriefingValidationPath() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--tron-ui-test-onboarding-complete")
        app.launch()

        openRecentSessionIfNeeded(in: app)

        let briefingButton = app.buttons["session-briefing-button"]
        XCTAssertTrue(briefingButton.waitForExistence(timeout: 20), "Context progress ring should open Session Briefing")
        briefingButton.tap()

        XCTAssertTrue(app.staticTexts["Session Briefing"].waitForExistence(timeout: 20), "Session Briefing sheet should open")
        XCTAssertTrue(app.staticTexts["Briefing"].waitForExistence(timeout: 10), "Narrative session briefing section should be visible")
        XCTAssertTrue(app.staticTexts["Context and Model Controls"].waitForExistence(timeout: 10), "Context/model controls should be visible")
        XCTAssertTrue(app.staticTexts["Context Breakdown"].waitForExistence(timeout: 10), "Context Breakdown section should be visible")
        XCTAssertTrue(app.staticTexts["context used"].waitForExistence(timeout: 10), "Context summary should render")

        let invalidPayloadError = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "did not return a Session Briefing payload")
        ).firstMatch
        XCTAssertFalse(invalidPayloadError.exists, "Session Briefing should not show an invalid server payload error")

        keepScreenshot(named: "session-briefing-sheet")

        let modelCard = app.buttons["session-briefing-model-card"]
        XCTAssertTrue(modelCard.waitForExistence(timeout: 15), "Model picker card should be available")
        modelCard.tap()

        XCTAssertTrue(app.staticTexts["Models"].waitForExistence(timeout: 20), "Model picker should open from Session Briefing")
        keepScreenshot(named: "session-briefing-model-picker")
    }

    @MainActor
    func testComposerGlassKeepsAttachmentMenuAndSessionBriefingInteractive() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--tron-ui-test-onboarding-complete")
        app.launch()
        openRecentSessionIfNeeded(in: app)

        let textView = app.textViews["Message input"]
        let textField = app.textFields["Message input"]
        let messageInput = textView.waitForExistence(timeout: 3) ? textView : textField
        XCTAssertTrue(messageInput.waitForExistence(timeout: 5), "Composer input should be available")
        messageInput.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Composer keyboard should open")

        let attachmentButton = app.buttons["Add attachment"]
        XCTAssertTrue(attachmentButton.waitForExistence(timeout: 20), "Composer attachment action should be available")
        let attachFiles = app.buttons["Attach Files"]

        for _ in 0..<3 {
            XCTAssertTrue(waitUntilHittable(attachmentButton), "Attachment action should recover after keyboard animation and menu dismissal")
            attachmentButton.tap()
            XCTAssertTrue(attachFiles.waitForExistence(timeout: 8), "Native attachment menu should open repeatedly over interactive glass")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
            XCTAssertTrue(waitUntilAbsent(attachFiles), "Native attachment menu should dismiss completely before reopening")
            XCTAssertTrue(app.keyboards.firstMatch.exists, "Attachment menu presentation should preserve composer keyboard focus")
        }

        let briefingButton = app.buttons["session-briefing-button"]
        XCTAssertTrue(briefingButton.waitForExistence(timeout: 10), "Context progress ring should remain interactive")
        briefingButton.tap()
        XCTAssertTrue(app.staticTexts["Session Briefing"].waitForExistence(timeout: 20), "Context progress ring should open Session Briefing")
    }

    @MainActor
    private func openRecentSessionIfNeeded(in app: XCUIApplication) {
        if app.buttons["session-briefing-button"].waitForExistence(timeout: 8) {
            return
        }

        let recentSession = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "last active")
        ).firstMatch
        XCTAssertTrue(recentSession.waitForExistence(timeout: 20), "A recent session row should be visible")
        recentSession.tap()
    }

    @MainActor
    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isHittable { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return element.exists && element.isHittable
    }

    @MainActor
    private func waitUntilAbsent(_ element: XCUIElement, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return !element.exists
    }

    @MainActor
    private func keepScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let directory = ProcessInfo.processInfo.environment["TRON_UI_SCREENSHOT_DIR"]
            ?? "/tmp/tron-ui-validation-screenshots"
        let url = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("\(name).png")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }
}
