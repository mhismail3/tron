import XCTest

final class TronCameraCaptureUITests: XCTestCase {
    @MainActor func testOnlyOpeningShowsLoadingAndSwitchesKeepControlsInPlace() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-tron-composer-upload-fixture", "-tron-camera-fixture",
            "-camera-fixture-start-latency-ms", "6000", "-camera-fixture-latency-ms", "3000",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
        defer { app.terminate() }
        waitFor(app.staticTexts["fixture.upload-connection"], "label BEGINSWITH 'connected'", "the fixture never connected")

        let attach = app.buttons["Add attachment"]
        XCTAssertTrue(attach.waitForExistence(timeout: 20), app.debugDescription)
        attach.tap()
        let takePhoto = app.buttons["Take Photo"]
        XCTAssertTrue(takePhoto.waitForExistence(timeout: 5), app.debugDescription)
        takePhoto.tap()

        let loading = app.descendants(matching: .any)["sheet-loading"]
        XCTAssertTrue(loading.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(loading.label, "Opening camera")
        XCTAssertEqual(loading.frame.midX, app.windows.firstMatch.frame.midX, accuracy: 1)
        keepScreenshot(app, "937-camera-opening")
        let history = app.descendants(matching: .any)["camera.phase-history"]
        waitFor(history, "label == 'starting>live'", "the back camera never went live")
        XCTAssertFalse(loading.exists, "the loading state outlived the first frame")

        let flash = app.buttons["Flashlight"]
        let shutter = app.buttons["Capture photo"]
        let flip = app.buttons["Switch Camera"]
        let controlFrames = [flash.frame, shutter.frame, flip.frame]
        XCTAssertTrue(flash.isEnabled, "the back camera has a torch")

        flip.tap()
        waitFor(history, "label BEGINSWITH 'starting>live>switching'", "the switch did not start")
        XCTAssertFalse(loading.exists, "switching cameras showed the loading state")
        keepScreenshot(app, "937-camera-switching")
        XCTAssertFalse(flash.isEnabled, "the torch stays off while the next camera starts")
        XCTAssertEqual([flash.frame, shutter.frame, flip.frame], controlFrames, "controls moved during the switch")
        waitFor(history, "label == 'starting>live>switching>live'", "the front camera never went live")
        XCTAssertFalse(flash.isEnabled, "the front camera has no torch")

        flip.tap()
        waitFor(history, "label == 'starting>live>switching>live>switching>live'", "the back camera never came back")
        XCTAssertTrue(flash.isEnabled)

        shutter.tap()
        let retake = app.buttons["Go back to capture"]
        XCTAssertTrue(retake.waitForExistence(timeout: 10), app.debugDescription)
        retake.tap()
        waitFor(history, "label ENDSWITH 'captured>resuming>live'", "the retake never went live")
        XCTAssertFalse(loading.exists)
        XCTAssertEqual([flash.frame, shutter.frame, flip.frame], controlFrames, "controls moved across capture and retake")
        XCTAssertFalse(history.label.contains("live>starting"), history.label)
        XCTAssertEqual(history.label.components(separatedBy: "starting").count, 2, "loading shown more than once: \(history.label)")

        shutter.tap()
        let use = app.buttons["Use photo"]
        XCTAssertTrue(use.waitForExistence(timeout: 10), app.debugDescription)
        use.tap()
        waitFor(app.staticTexts["fixture.upload-counts"], "label CONTAINS 'camera:1'", "the photo was not attached")
        XCTAssertTrue(app.buttons["Remove photo.jpg"].waitForExistence(timeout: 10), app.debugDescription)

        keepScreenshot(app, "937-camera-photo-attached")
    }

    @MainActor private func keepScreenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor private func waitFor(_ element: XCUIElement, _ predicate: String, _ message: String) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 20),
            .completed,
            "\(message): \(element.exists ? element.label : "missing")"
        )
    }
}
