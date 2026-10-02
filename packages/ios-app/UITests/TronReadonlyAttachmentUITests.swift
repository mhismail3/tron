import XCTest

final class TronReadonlyAttachmentUITests: XCTestCase {
    @MainActor func testDownloadedImageSelectionAndZoomSurviveBackgroundReconnect() {
        continueAfterFailure = false
        let app = launch("image"); defer { app.terminate() }
        let image = openImage(app)
        image.doubleTap()
        XCTAssertTrue(wait(app.staticTexts["fixture.preview-native"], predicate: "label BEGINSWITH 'image native:' AND NOT label CONTAINS 'zoom:1.00'"))
        let before = app.staticTexts["fixture.preview-native"].label
        keepScreenshot(app, "348-readonly-image-before")
        XCUIDevice.shared.press(.home); app.activate()
        waitConnected(app)
        XCTAssertTrue(image.waitForExistence(timeout: 10), "The original selected readonly image remains presented")
        XCTAssertTrue(wait(app.staticTexts["fixture.preview-native"], predicate: "label == %@", value: before), "The mounted native viewport and zoom are preserved")
        keepEvidence(app, name: "348-readonly-image-after")
    }

    @MainActor func testDownloadedFileSelectionAndViewportSurviveBackgroundReconnect() {
        continueAfterFailure = false
        let app = launch("file"); defer { app.terminate() }
        let file = app.otherElements.matching(NSPredicate(format: "label BEGINSWITH 'File attachment, readonly.txt'")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 15)); file.tap()
        let reader = app.textViews.matching(NSPredicate(format: "value BEGINSWITH 'Readonly fixture row'")).firstMatch
        XCTAssertTrue(reader.waitForExistence(timeout: 10))
        reader.swipeUp(); reader.swipeUp()
        reader.press(forDuration: 1.2)
        XCTAssertTrue(wait(app.staticTexts["fixture.preview-native"], predicate: "label BEGINSWITH 'file native:' AND NOT label CONTAINS 'offset:0' AND NOT label ENDSWITH ':0'"))
        let before = app.staticTexts["fixture.preview-native"].label
        keepScreenshot(app, "348-readonly-file-before")
        XCUIDevice.shared.press(.home); app.activate()
        waitConnected(app)
        XCTAssertTrue(reader.waitForExistence(timeout: 10), "The original downloaded readonly file remains presented")
        XCTAssertTrue(wait(app.staticTexts["fixture.preview-native"], predicate: "label == %@", value: before), "The native reader, offset and selection remain identical")
        keepEvidence(app, name: "348-readonly-file-after")
    }

    @MainActor func testDownloadedDisplayImageRouteSurvivesBackgroundReconnect() {
        continueAfterFailure = false
        let app = launch("display-image"); defer { app.terminate() }
        let button = app.buttons["Open Orientation Image photo preview"]
        XCTAssertTrue(button.waitForExistence(timeout: 15)); button.tap()
        let image = app.images["Red above blue, with the close badge at top right."]
        XCTAssertTrue(image.waitForExistence(timeout: 10))
        image.doubleTap()
        XCTAssertTrue(wait(app.staticTexts["fixture.preview-native"], predicate: "label BEGINSWITH 'image native:' AND NOT label CONTAINS 'zoom:1.00'"))
        let before = app.staticTexts["fixture.preview-native"].label
        XCUIDevice.shared.press(.home); app.activate()
        waitConnected(app)
        XCTAssertTrue(image.waitForExistence(timeout: 10), "Static display selection is not a live/browser lease")
        XCTAssertTrue(wait(app.staticTexts["fixture.preview-native"], predicate: "label == %@", value: before))
        keepEvidence(app, name: "348-readonly-display-image-after")
    }

    @MainActor func testDownloadedDisplayFileRouteAndReaderSurviveReconnect() {
        continueAfterFailure = false
        let app = launch("display-file"); defer { app.terminate() }
        let button = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Readonly display file'")).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 15)); button.tap()
        let readers = app.textViews.matching(NSPredicate(format: "value BEGINSWITH 'Readonly fixture row'"))
        XCTAssertTrue(readers.firstMatch.waitForExistence(timeout: 10))
        guard let reader = readers.allElementsBoundByIndex.first(where: { $0.isHittable }) else { XCTFail("The actual sheet reader must be hittable"); return }
        reader.swipeUp(); reader.press(forDuration: 1.2)
        XCTAssertTrue(wait(app.staticTexts["fixture.preview-native"], predicate: "label BEGINSWITH 'file native:' AND NOT label CONTAINS 'offset:0' AND NOT label ENDSWITH ':0'"))
        let before = app.staticTexts["fixture.preview-native"].label
        XCUIDevice.shared.press(.home); app.activate(); waitConnected(app)
        XCTAssertTrue(reader.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(app.staticTexts["fixture.preview-native"], predicate: "label == %@", value: before))
        keepEvidence(app, name: "348-readonly-display-file-after")
    }

    @MainActor func testRetiredImagePreparationCannotPublishOnRetainedSheet() {
        continueAfterFailure = false
        let app = launch("image-held"); defer { app.terminate() }
        let button = app.buttons["Image attachment"]
        XCTAssertTrue(button.waitForExistence(timeout: 15)); button.tap()
        XCTAssertTrue(wait(app.staticTexts["fixture.preview-counts"], predicate: "label CONTAINS 'held:1'"))
        XCUIDevice.shared.press(.home); app.activate(); waitConnected(app)
        XCTAssertTrue(wait(app.staticTexts["fixture.preview-counts"], predicate: "label CONTAINS 'released:1'"))
        XCTAssertTrue(wait(app.staticTexts["fixture.preview-native"], predicate: "label CONTAINS 'height:320'"), "A new admitted preparation rejoins the original selection")
        XCTAssertEqual(app.staticTexts["fixture.preview-poison"].label, "poison:false", "The retired preparation must never replace the readonly viewport")
        keepEvidence(app, name: "348-readonly-retired-preparation")
    }

    @MainActor func testImageHeldThroughForegroundReadyRequiresFreshAttempt() {
        assertForegroundHeldPreparation("image-foreground-held", file: false)
    }
    @MainActor func testFileHeldThroughForegroundReadyRequiresFreshAttempt() {
        assertForegroundHeldPreparation("file-held-foreground-held", file: true)
    }
    @MainActor private func assertForegroundHeldPreparation(_ scenario: String, file: Bool) {
        continueAfterFailure = false
        let app = launch(scenario); defer { app.terminate() }
        let button = file ? app.otherElements.matching(NSPredicate(format: "label BEGINSWITH 'File attachment, readonly.txt'")).firstMatch : app.buttons["Image attachment"]
        XCTAssertTrue(button.waitForExistence(timeout: 15)); button.tap()
        XCTAssertTrue(wait(app.staticTexts["fixture.preview-counts"], predicate: "label CONTAINS 'held:1'"))
        XCUIDevice.shared.press(.home); app.activate(); waitConnected(app)
        XCTAssertTrue(wait(app.staticTexts["fixture.preview-counts"], predicate: "label CONTAINS 'released:1'"), "Predecessor is withheld until successor read admission on foreground transport")
        XCTAssertTrue(wait(app.staticTexts["fixture.preview-native"], predicate: file ? "label BEGINSWITH 'file native:'" : "label CONTAINS 'height:320'"), "Fresh valid preparation must rejoin the retained original sheet")
        XCTAssertEqual(app.staticTexts["fixture.preview-poison"].label, "poison:false")
        keepEvidence(app, name: "348-foreground-held-\(file ? "file" : "image")")
    }

    @MainActor func testProfileReplacementRevokesDownloadedReadonlySelection() {
        assertReplacementClosesPreview("image-replace-profile", held: false)
    }
    @MainActor func testProfileReplacementRevokesDownloadedFileReader() {
        continueAfterFailure = false
        let app = launch("file-replace-profile"); defer { app.terminate() }
        let file = app.otherElements.matching(NSPredicate(format: "label BEGINSWITH 'File attachment, readonly.txt'")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 15)); file.tap()
        XCTAssertTrue(wait(app.staticTexts["fixture.preview-native"], predicate: "label BEGINSWITH 'file native:'"))
        XCUIDevice.shared.press(.home); app.activate(); waitConnected(app)
        XCTAssertTrue(wait(app.staticTexts["fixture.preview-counts"], predicate: "NOT label CONTAINS 'opens:1 '"))
        XCTAssertTrue(wait(app.staticTexts["fixture.preview-native"], predicate: "label == 'none'"))
        XCTAssertFalse(app.textViews.matching(NSPredicate(format: "value BEGINSWITH 'Readonly fixture row'")).firstMatch.exists)
        keepEvidence(app, name: "348-readonly-file-profile-replacement")
    }
    @MainActor func testProfileReplacementFencesHeldPreparation() {
        assertReplacementClosesPreview("image-held-replace-profile", held: true)
    }
    @MainActor func testSessionReplacementRevokesDownloadedReadonlySelection() {
        assertReplacementClosesPreview("image-replace-session", held: false)
    }
    @MainActor private func assertReplacementClosesPreview(_ scenario: String, held: Bool) {
        continueAfterFailure = false
        let app = launch(scenario); defer { app.terminate() }
        if held {
            let button = app.buttons["Image attachment"]
            XCTAssertTrue(button.waitForExistence(timeout: 15)); button.tap()
            XCTAssertTrue(wait(app.staticTexts["fixture.preview-counts"], predicate: "label CONTAINS 'held:1'"))
        } else { _ = openImage(app) }
        XCUIDevice.shared.press(.home); app.activate(); waitConnected(app)
        XCTAssertTrue(wait(app.staticTexts["fixture.preview-counts"], predicate: "NOT label CONTAINS 'opens:1 '"))
        XCTAssertTrue(wait(app.staticTexts["fixture.preview-native"], predicate: "label == 'none'"))
        XCTAssertFalse(app.images["Preview photo"].exists, "An old selection must not reattach to another authority/session")
        XCTAssertEqual(app.staticTexts["fixture.preview-poison"].label, "poison:false")
        keepEvidence(app, name: "348-readonly-\(scenario)")
    }

    @MainActor private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-readonly-attachment-fixture", "-readonly-preview-scenario", scenario, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); return app
    }
    @MainActor private func openImage(_ app: XCUIApplication) -> XCUIElement {
        let button = app.buttons["Image attachment"]
        XCTAssertTrue(button.waitForExistence(timeout: 15)); button.tap()
        let image = app.images["Preview photo"]
        XCTAssertTrue(image.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(app.staticTexts["fixture.preview-native"], predicate: "label CONTAINS 'height:320'"), "The full readonly image has been downloaded before viewport interaction")
        return image
    }
    @MainActor private func waitConnected(_ app: XCUIApplication) {
        XCTAssertTrue(wait(app.staticTexts["fixture.preview-connection"], predicate: "label BEGINSWITH 'connected' AND NOT label CONTAINS 'socket:none'"))
    }
    @MainActor private func wait(_ element: XCUIElement, predicate: String, value: String? = nil) -> Bool {
        let condition = value.map { NSPredicate(format: predicate, $0) } ?? NSPredicate(format: predicate)
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: condition, object: element)], timeout: 10) == .completed
    }
    @MainActor private func keepEvidence(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(string: "before=\(app.staticTexts["fixture.preview-before"].label)\nafter=\(app.staticTexts["fixture.preview-native"].label)\n\(app.staticTexts["fixture.preview-counts"].label)")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        keepScreenshot(app, name)
    }
    @MainActor private func keepScreenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
