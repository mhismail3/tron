import XCTest

/// Investigation-only capture driver; no acceptance verdict for foreground stability.
/// Formal regression oracles follow the maintainer's visual checkpoint approval.
final class TronForegroundCaptureUITests: XCTestCase {
    @MainActor func testCaptureHomeLight() { captureHome(dark: false) }
    @MainActor func testCaptureHomeDark() { captureHome(dark: true) }

    @MainActor func testCaptureHomeSettingsLight() { captureHomeSettings(dark: false) }
    @MainActor func testCaptureHomeSettingsDark() { captureHomeSettings(dark: true) }

    @MainActor private func captureHomeSettings(dark: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-foreground-sheet-probe"]
            + (dark ? ["-home-dark"] : [])
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 20))
        app.buttons["home-pinned-row"].tap()
        XCTAssertTrue(app.buttons["session-context-button"].waitForExistence(timeout: 20))
        app.buttons["session-context-button"].tap()
        XCTAssertTrue(app.buttons["home-sheet-done-manage"].waitForExistence(timeout: 20))
        let settings = app.descendants(matching: .any)["home-manage-settings"].firstMatch
        reveal(settings, in: app)
        settings.tap()
        let models = app.buttons["settings-section-model-open"]
        XCTAssertTrue(models.waitForExistence(timeout: 20), app.debugDescription)
        reveal(models, in: app); models.tap()
        let thinking = app.buttons.matching(NSPredicate(format: "label == %@", "Worker thinking")).firstMatch
        XCTAssertTrue(thinking.waitForExistence(timeout: 20), app.debugDescription)
        reveal(thinking, in: app); thinking.tap()
        XCTAssertTrue(app.buttons["settings-option-Low"].waitForExistence(timeout: 20), app.debugDescription)
        capture(app, name: "home-settings-choice-\(dark ? "dark" : "light")")
    }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }

    @MainActor private func captureHome(dark: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-foreground-sheet-probe"]
            + (dark ? ["-home-dark"] : [])
        app.launch(); defer { app.terminate() }
        let home = app.buttons["home-pinned-row"]
        XCTAssertTrue(home.waitForExistence(timeout: 20), app.debugDescription)
        home.tap()
        let ring = app.buttons["session-context-button"]
        XCTAssertTrue(ring.waitForExistence(timeout: 20))
        ring.tap()
        let manageDone = app.buttons["home-sheet-done-manage"]
        XCTAssertTrue(manageDone.waitForExistence(timeout: 20))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
        let memory = app.descendants(matching: .any)["home-manage-memory-browser"].firstMatch
        if !memory.isHittable { app.swipeUp() }
        XCTAssertTrue(memory.waitForExistence(timeout: 20))
        memory.tap()
        let memoryDone = app.buttons["home-sheet-done-memory"]
        XCTAssertTrue(memoryDone.waitForExistence(timeout: 20))
        capture(app, name: "memory-\(dark ? "dark" : "light")")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
        let item = app.descendants(matching: .any)["home-memory-row-39"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 20))
        item.tap()
        XCTAssertTrue(app.buttons["home-sheet-done-memory-item"].waitForExistence(timeout: 20))
        capture(app, name: "memory-item-\(dark ? "dark" : "light")")
        app.buttons["home-sheet-done-memory-item"].tap()
        memoryDone.tap()
        capture(app, name: "manage-revealed-\(dark ? "dark" : "light")")
    }

    @MainActor private func capture(_ app: XCUIApplication, name: String) {
        Thread.sleep(forTimeInterval: 1)
        let reads = app.staticTexts["fixture.home-read-counts"].firstMatch
        print("FOREGROUND_CAPTURE before \(name) \(Date().timeIntervalSince1970) \(reads.exists ? reads.label : "no read label")")
        evidence(app, name: "\(name)-before")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 15))
        Thread.sleep(forTimeInterval: 1)
        print("FOREGROUND_CAPTURE activate \(name) \(Date().timeIntervalSince1970)")
        app.activate()
        Thread.sleep(forTimeInterval: 2)
        print("FOREGROUND_CAPTURE after \(name) \(Date().timeIntervalSince1970) \(reads.exists ? reads.label : "no read label")")
        evidence(app, name: "\(name)-after")
    }

    @MainActor private func evidence(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name)-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
