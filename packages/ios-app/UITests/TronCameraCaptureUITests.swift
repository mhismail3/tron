import XCTest

/// The Take Photo sheet (#937), opened from the real composer menu against
/// scripted camera hardware (`HostedCameraFixture`): each feed becomes live
/// 1.5 s after it is requested. `camera.phase-history` is the model's complete
/// phase sequence, so "never shows loading again" is an exact assertion, not a
/// sampled one.
final class TronCameraCaptureUITests: XCTestCase {
    /// Opening shows the shared sheet loading state once; switching cameras and
    /// retaking hold the last frame instead, keep the controls in place, and
    /// follow the torch of the camera that is live. The used photo attaches.
    @MainActor func testOnlyOpeningShowsLoadingAndSwitchesKeepControlsInPlace() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-tron-composer-upload-fixture", "-tron-camera-fixture", "-camera-fixture-latency-ms", "1500",
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

        // Opening: the shared sheet loading state, centred over the sheet.
        let loading = app.descendants(matching: .any)["sheet-loading"]
        XCTAssertTrue(loading.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(loading.label, "Opening camera")
        XCTAssertEqual(loading.frame.midX, app.windows.firstMatch.frame.midX, accuracy: 1)
        let history = app.descendants(matching: .any)["camera.phase-history"]
        waitFor(history, "label == 'starting>live'", "the back camera never went live")
        XCTAssertFalse(loading.exists, "the loading state outlived the first frame")

        let flash = app.buttons["Flashlight"]
        let shutter = app.buttons["Capture photo"]
        let flip = app.buttons["Switch Camera"]
        let controlFrames = [flash.frame, shutter.frame, flip.frame]
        XCTAssertTrue(flash.isEnabled, "the back camera has a torch")

        // Back to front: the held frame replaces the loading state.
        flip.tap()
        waitFor(history, "label == 'starting>live>switching'", "the switch did not start")
        XCTAssertFalse(loading.exists, "switching cameras showed the loading state")
        XCTAssertFalse(flash.isEnabled, "the torch stays off while the next camera starts")
        XCTAssertEqual([flash.frame, shutter.frame, flip.frame], controlFrames, "controls moved during the switch")
        waitFor(history, "label == 'starting>live>switching>live'", "the front camera never went live")
        XCTAssertFalse(flash.isEnabled, "the front camera has no torch")

        // Front to back: the torch returns with the back camera.
        flip.tap()
        waitFor(history, "label == 'starting>live>switching>live>switching>live'", "the back camera never came back")
        XCTAssertTrue(flash.isEnabled)

        // Capture, retake (held photo, no loading), capture again and attach.
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

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "937-camera-photo-attached"
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
