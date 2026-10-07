import XCTest
import UIKit

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

    @MainActor func testVideoDisplaySheetOpensAtMediumPlaysAndExpandsToLarge() {
        continueAfterFailure = false
        for scenario in ["display-video", "display-video-light", "display-video-accessibility", "display-video-light-accessibility"] {
            let app = launch(scenario); defer { app.terminate() }
            let transcriptPlayer = app.otherElements["display.video.player"]
            XCTAssertTrue(transcriptPlayer.waitForExistence(timeout: 15), "\(scenario): transcript video is mounted")
            let expand = app.buttons["Open Inline video fixture in sheet"]
            XCTAssertTrue(expand.waitForExistence(timeout: 10)); expand.tap()
            let done = app.buttons["Done"]
            XCTAssertTrue(done.waitForExistence(timeout: 10), "\(scenario): shared document sheet chrome is installed")
            let sheetPlayer = app.otherElements["display.video.sheet.player"]
            XCTAssertTrue(sheetPlayer.waitForExistence(timeout: 10), "\(scenario): video player is visible in the sheet")
            let mediumTop = done.frame.minY
            XCTAssertGreaterThan(mediumTop, app.windows.firstMatch.frame.height * 0.40, "\(scenario): sheet begins at medium")
            let mediumPlayerFrame = sheetPlayer.frame
            XCTAssertGreaterThanOrEqual(mediumPlayerFrame.height, 220, "\(scenario): the player has its bounded viewport at medium")
            XCTAssertGreaterThanOrEqual(mediumPlayerFrame.minY, done.frame.maxY, "\(scenario): player begins below the shared title and top blur")
            XCTAssertLessThanOrEqual(mediumPlayerFrame.maxY, app.windows.firstMatch.frame.maxY, "\(scenario): player remains inside the medium sheet")
            XCTAssertTrue(sheetPlayer.isHittable, "\(scenario): player controls can receive interaction at medium")

            let clocks = app.staticTexts.matching(identifier: "display.video.sheet.playback-time")
            XCTAssertTrue(clocks.firstMatch.waitForExistence(timeout: 10))
            let clock = clocks.element(boundBy: clocks.count - 1)
            let initialTime = Double(clock.label) ?? 0
            sheetPlayer.tap()
            var advanced = false
            for _ in 0..<30 {
                if (Double(clock.label) ?? initialTime) > initialTime + 0.2 { advanced = true; break }
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            XCTAssertTrue(advanced, "\(scenario): playback advances without enlarging the sheet")
            XCTAssertGreaterThan(done.frame.minY, app.windows.firstMatch.frame.height * 0.40, "\(scenario): playback leaves the sheet at medium")
            RunLoop.current.run(until: Date().addingTimeInterval(5.5))
            keepScreenshot(app, "520-video-medium-playing-\(scenario)")
            assertGeneratedVideoFrame(in: app, player: sheetPlayer, scenario: scenario)

            sheetPlayer.tap()
            let playPause = app.buttons["Play/Pause"]
            XCTAssertTrue(playPause.waitForExistence(timeout: 3), "\(scenario): visible native playback controls are reachable")
            XCTAssertTrue(playPause.isHittable, "\(scenario): native play/pause control is reachable at medium")
            if playPause.label == "Pause" { playPause.tap() }
            XCTAssertEqual(playPause.label, "Play", "\(scenario): native control reports the paused state")
            let pausedTime = Double(clock.label) ?? 0
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            XCTAssertEqual(Double(clock.label) ?? pausedTime, pausedTime, accuracy: 0.05, "\(scenario): playback can be paused at medium")
            keepScreenshot(app, "520-video-medium-paused-controls-\(scenario)")

            app.swipeUp()
            let expanded = NSPredicate { element, _ in
                guard let button = element as? XCUIElement else { return false }
                return button.frame.minY < mediumTop - 100
            }
            expectation(for: expanded, evaluatedWith: done)
            waitForExpectations(timeout: 8)
            XCTAssertTrue(sheetPlayer.exists && sheetPlayer.isHittable, "\(scenario): player survives the large detent")
            XCTAssertGreaterThan(sheetPlayer.frame.height, mediumPlayerFrame.height + 100, "\(scenario): the player re-lays out with the expanded detent")
            let largePlayPause = app.buttons["Play/Pause"]
            if largePlayPause.label == "Play" { largePlayPause.tap() }
            RunLoop.current.run(until: Date().addingTimeInterval(5.5))
            keepScreenshot(app, "520-video-large-\(scenario)")
            assertGeneratedVideoFrame(in: app, player: sheetPlayer, scenario: scenario)
        }
    }

    @MainActor func testDocumentDisplaySheetKeepsExistingLargeDetent() {
        continueAfterFailure = false
        let app = launch("display-file"); defer { app.terminate() }
        let display = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Readonly display file'" )).firstMatch
        XCTAssertTrue(display.waitForExistence(timeout: 15)); display.tap()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        keepScreenshot(app, "520-document-sheet-large-negative-control")
        XCTAssertLessThan(done.frame.minY, app.windows.firstMatch.frame.height * 0.35, "Document display retains its existing large-only detent")
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
        if scenario.contains("accessibility") {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
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
    @MainActor private func assertGeneratedVideoFrame(
        in app: XCUIApplication,
        player: XCUIElement,
        scenario: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let image = XCUIScreen.main.screenshot().image.cgImage else {
            XCTFail("\(scenario): screenshot has no image", file: file, line: line)
            return
        }
        let viewport = player.frame
        let fittedSide = min(viewport.width, viewport.height)
        let screenFrame = app.frame
        let point = CGPoint(x: viewport.midX + fittedSide * 0.18, y: viewport.midY + fittedSide * 0.18)
        let x = Int((point.x - screenFrame.minX) * CGFloat(image.width) / screenFrame.width)
        let y = Int((point.y - screenFrame.minY) * CGFloat(image.height) / screenFrame.height)
        guard x >= 0, x < image.width, y >= 0, y < image.height,
              let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else {
            XCTFail("\(scenario): video sample point is outside the captured viewport", file: file, line: line)
            return
        }
        var rgba = [UInt8](repeating: 0, count: 4)
        let color = rgba.withUnsafeMutableBytes { buffer -> (UInt8, UInt8, UInt8)? in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return nil }
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return (buffer[0], buffer[1], buffer[2])
        }
        guard let (red, green, blue) = color else {
            XCTFail("\(scenario): screenshot pixel could not be sampled", file: file, line: line)
            return
        }
        XCTAssertLessThan(red, 145, "\(scenario): generated cyan frame should retain its distinct red channel, got RGB(\(red), \(green), \(blue))", file: file, line: line)
        XCTAssertGreaterThan(green, 165, "\(scenario): generated video frame must retain its green channel, got RGB(\(red), \(green), \(blue))", file: file, line: line)
        XCTAssertGreaterThan(blue, 165, "\(scenario): generated video frame must retain its blue channel, got RGB(\(red), \(green), \(blue))", file: file, line: line)
        XCTAssertGreaterThan(green, red + 45, "\(scenario): screenshot must contain the decoded cyan video, not a grayscale/blurred placeholder", file: file, line: line)
        XCTAssertGreaterThan(blue, red + 45, "\(scenario): screenshot must contain the decoded cyan video, not a grayscale/blurred placeholder", file: file, line: line)
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
