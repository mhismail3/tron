import XCTest

final class TronToolSheetsPolishUITests: XCTestCase {

    @MainActor func testTaskMessageHeaderAndFullReaderForReview() {
        continueAfterFailure = false
        for mode in ["light", "dark"] {
            for large in [false, true] {
                let app = XCUIApplication()
                app.launchArguments = ["-tron-tool-sheets-polish-fixture", "-polish-scenario", "task-message", "-polish-\(mode)"]
                if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
                app.launch()
                let detail = app.descendants(matching: .any)["home-tool-detail"]
                XCTAssertTrue(detail.waitForExistence(timeout: 15))
                XCTAssertFalse(detail.descendants(matching: .any)["home-tool-row-Task ID"].exists)
                let delivery = app.staticTexts["Message (Delivered to the worker's running operation.)"]
                XCTAssertTrue(delivery.exists, app.debugDescription)
                let suffix = "\(mode)-\(large ? "large" : "standard")"
                capture(app, "1325-task-message-\(suffix)")
                let reader = app.buttons["home-tool-text-message-view-all"]
                for _ in 0..<12 where !reader.isHittable { app.swipeUp() }
                XCTAssertTrue(reader.isHittable)
                XCTAssertEqual(reader.label, "View full message")
                reader.tap()
                XCTAssertTrue(app.descendants(matching: .any)["home-reading-text"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Wait for visual approval")).firstMatch.exists)
                capture(app, "1325-task-full-message-\(suffix)")
                let done = app.buttons.matching(NSPredicate(format: "label == %@", "Done")).allElementsBoundByIndex.last { $0.isHittable }
                XCTAssertNotNil(done, app.debugDescription)
                done?.tap()
                XCTAssertTrue(delivery.waitForExistence(timeout: 5), "Closing the reader returns to the same delivery summary")
                XCTAssertTrue(detail.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "photo-readiness")).firstMatch.exists)
                app.terminate()
            }
        }
    }

    @MainActor func testOnlyOverflowingPromptOpensFullMarkdownReader() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-tool-sheets-polish-fixture", "-polish-scenario", "prompt", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let prompt = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Fix: attaching photos'")).firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertLessThan(prompt.frame.height, app.windows.firstMatch.frame.height, "The long prompt has a bounded viewport")
        prompt.tap()
        let reader = app.descendants(matching: .any)["home-reading-text"]
        XCTAssertTrue(reader.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Prompt"].exists)
        let tail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Wait for visual approval before behavioral regression runs or merging.")).firstMatch
        for _ in 0..<8 where !tail.isHittable { app.swipeUp() }
        XCTAssertTrue(tail.isHittable, "The reader must expose the original text beyond the truncated viewport")
        capture(app, "1302-full-prompt-reader-tail")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(reader.waitForNonExistence(timeout: 10))
        app.terminate()
        app.launchArguments = ["-tron-tool-sheets-polish-fixture", "-polish-scenario", "short-prompt", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let short = app.staticTexts["Please inspect the selected photos and keep the current layout."]
        XCTAssertTrue(short.waitForExistence(timeout: 15), app.debugDescription)
        short.tap()
        XCTAssertFalse(reader.exists, "An untruncated prompt must not acquire a detail-sheet action")
        XCTAssertFalse(app.staticTexts["Prompt"].exists)
        short.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 5), "The short prompt retains its original context menu")
        XCTAssertFalse(reader.exists, "Long press must not open the prompt reader")
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 0.7)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
