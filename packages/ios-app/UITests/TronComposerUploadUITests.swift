import XCTest

/// Composer photo staging across a background reconnect (#916). The fixture
/// scripts only the Gateway: four photos are pasted through the composer's own
/// edit menu, the third transfer is in flight when the app backgrounds, and the
/// fixture counts every staging attempt the Gateway receives.
final class TronComposerUploadUITests: XCTestCase {
    /// Already-staged photos survive the reconnect to the same Mac and a
    /// reopened chat: only the interrupted and unstarted photos are uploaded
    /// again, and the message sends with all four attachments.
    @MainActor func testBackgroundMidUploadReusesStagedPhotosAfterReconnect() {
        continueAfterFailure = false
        let app = launch("reconnect"); defer { app.terminate() }
        pastePhotos(app)
        XCTAssertTrue(waitCounts(app, "held:1"), "the third photo never reached the Gateway: \(counts(app))")
        XCUIDevice.shared.press(.home)
        app.activate()
        waitConnected(app)

        XCTAssertTrue(waitCounts(app, "staged:1,1,1,1"), "every photo is staged exactly once after the reconnect: \(counts(app))")
        // Leaving and reopening the chat keeps the staged photos too.
        app.buttons["fixture.reopen-chat"].tap()
        XCTAssertTrue(app.textViews["Message input"].waitForExistence(timeout: 20), app.debugDescription)
        send(app)
        XCTAssertTrue(waitCounts(app, "prompts:4 "), "the message sends with all four photos: \(counts(app))")
        let final = counts(app)
        XCTAssertTrue(final.contains("staged:1,1,1,1 restaged:0"), "no staged photo is uploaded again: \(final)")
        XCTAssertTrue(final.contains("rejected:0"), final)
        keepEvidence(app, "916-reused-staged-photos")
    }

    /// When the Mac no longer holds the staged photos (expired or reset staging),
    /// the rejected send restores the draft, every photo uploads again, and the
    /// next send carries all four.
    @MainActor func testLostStagingReuploadsEveryPhotoAndSends() {
        continueAfterFailure = false
        let app = launch("lost-staging"); defer { app.terminate() }
        pastePhotos(app)
        XCTAssertTrue(waitCounts(app, "held:1"), counts(app))
        XCUIDevice.shared.press(.home)
        app.activate()
        waitConnected(app)

        XCTAssertTrue(waitCounts(app, "staged:1,1,1,1"), counts(app))
        send(app)
        XCTAssertTrue(waitCounts(app, "rejected:1"), "the Gateway rejects the lost staged photos: \(counts(app))")
        XCTAssertTrue(waitCounts(app, "staged:2,2,2,2"), "every rejected photo uploads again: \(counts(app))")
        send(app)
        XCTAssertTrue(waitCounts(app, "prompts:4 "), "the retried message sends with all four photos: \(counts(app))")
        keepEvidence(app, "916-lost-staging-reupload")
    }

    @MainActor private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-composer-upload-fixture", "-composer-upload-scenario", scenario, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    @MainActor private func pastePhotos(_ app: XCUIApplication) {
        waitConnected(app)
        let composer = app.textViews["Message input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20), app.debugDescription)
        composer.tap()
        let paste = app.menuItems["Paste"]
        for _ in 0..<3 where !paste.exists {
            composer.press(forDuration: 1.0)
            if paste.waitForExistence(timeout: 3) { break }
        }
        XCTAssertTrue(paste.exists, "the composer edit menu offers Paste: \(app.debugDescription)")
        paste.tap()
    }

    @MainActor private func send(_ app: XCUIApplication) {
        let send = app.buttons["Send message"]
        XCTAssertTrue(send.waitForExistence(timeout: 20), app.debugDescription)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: send)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 20), .completed, "send stays disabled: \(counts(app))")
        send.tap()
    }

    @MainActor private func counts(_ app: XCUIApplication) -> String {
        app.staticTexts["fixture.upload-counts"].label
    }

    @MainActor private func waitCounts(_ app: XCUIApplication, _ fragment: String) -> Bool {
        let condition = NSPredicate(format: "label CONTAINS %@", fragment)
        return XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: condition, object: app.staticTexts["fixture.upload-counts"])],
            timeout: 20
        ) == .completed
    }

    @MainActor private func waitConnected(_ app: XCUIApplication) {
        let condition = NSPredicate(format: "label BEGINSWITH 'connected'")
        XCTAssertEqual(XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: condition, object: app.staticTexts["fixture.upload-connection"])],
            timeout: 30
        ), .completed, "the fixture never connected: \(app.staticTexts["fixture.upload-connection"].label)")
    }

    @MainActor private func keepEvidence(_ app: XCUIApplication, _ name: String) {
        let text = XCTAttachment(string: counts(app))
        text.name = name; text.lifetime = .keepAlways; add(text)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
