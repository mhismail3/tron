import XCTest

/// Investigation-only capture driver; no acceptance verdict for foreground stability.
/// Formal regression oracles follow the maintainer's visual checkpoint approval.
final class TronForegroundCaptureUITests: XCTestCase {
    @MainActor func testCaptureHomeLight() { captureHome(dark: false) }
    @MainActor func testCaptureHomeDark() { captureHome(dark: true) }

    @MainActor func testCaptureHomeSettingsLight() { captureHomeSettings(dark: false) }
    @MainActor func testCaptureHomeSettingsDark() { captureHomeSettings(dark: true) }
    @MainActor func testCaptureRemovedSettingsSourceDark() { captureHomeSettings(dark: true, removed: true) }
    @MainActor func testCaptureProvidersLight() { captureProviders(dark: false) }
    @MainActor func testCaptureProvidersDark() { captureProviders(dark: true) }
    @MainActor func testCaptureSessionSettingsLight() { captureSessionSettings(dark: false) }
    @MainActor func testCaptureSessionSettingsDark() { captureSessionSettings(dark: true) }
    @MainActor func testCaptureQueuedEditorLight() { captureQueuedEditor(dark: false) }
    @MainActor func testCaptureQueuedEditorDark() { captureQueuedEditor(dark: true) }

    @MainActor private func captureHomeSettings(dark: Bool, removed: Bool = false) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-foreground-sheet-probe", "-foreground-settings-change"]
            + (dark ? ["-home-dark"] : []) + (removed ? ["-foreground-settings-removed"] : [])
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
        capture(app, name: "home-settings-\(removed ? "removed" : "choice")-\(dark ? "dark" : "light")")
        for layer in (removed ? ["home-settings", "manage"] : ["models", "home-settings", "manage"]) {
            closeTop(app)
            markReveal(app, name: "\(layer)-\(dark ? "dark" : "light")")
        }
        app.buttons["home-sheet-done-manage"].tap()
        app.buttons["Back"].tap()
        evidence(app, name: "settings-stack-retired")
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
        manageDone.tap(); app.buttons["Back"].tap()
        evidence(app, name: "memory-stack-retired")
    }

    @MainActor private func launch(_ dark: Bool, arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-foreground-sheet-probe"]
            + arguments + (dark ? ["-home-dark"] : [])
        app.launch()
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 20))
        return app
    }

    @MainActor private func captureProviders(dark: Bool) {
        continueAfterFailure = false
        let app = launch(dark); defer { app.terminate() }
        app.buttons["home-pinned-row"].tap()
        XCTAssertTrue(app.navigationBars.buttons["Settings"].waitForExistence(timeout: 20))
        app.navigationBars.buttons["Settings"].tap()
        let providers = app.buttons["settings-link-Model Providers"]
        XCTAssertTrue(providers.waitForExistence(timeout: 20)); reveal(providers, in: app); providers.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Providers"].waitForExistence(timeout: 20), app.debugDescription)
        capture(app, name: "providers-\(dark ? "dark" : "light")")
        closeTop(app); app.buttons["settings-done"].tap(); app.buttons["Back"].tap()
        evidence(app, name: "providers-stack-retired")
    }

    @MainActor private func captureSessionSettings(dark: Bool) {
        continueAfterFailure = false
        let app = launch(dark); defer { app.terminate() }
        let ordinary = app.buttons["session-row-home-shell-fixture:ordinary-session"]
        XCTAssertTrue(ordinary.waitForExistence(timeout: 20)); ordinary.tap()
        XCTAssertTrue(app.buttons["session-context-button"].waitForExistence(timeout: 20))
        app.buttons["session-context-button"].tap()
        let settings = app.buttons["chat-settings-link"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20)); reveal(settings, in: app); settings.tap()
        let connection = app.buttons["settings-section-advanced-open"]
        XCTAssertTrue(connection.waitForExistence(timeout: 20), app.debugDescription)
        reveal(connection, in: app); connection.tap()
        let transport = app.buttons.matching(NSPredicate(format: "label == %@", "Transport")).firstMatch
        XCTAssertTrue(transport.waitForExistence(timeout: 20), app.debugDescription)
        reveal(transport, in: app); transport.tap()
        XCTAssertTrue(app.buttons["settings-option-Automatic"].waitForExistence(timeout: 20), app.debugDescription)
        capture(app, name: "session-settings-choice-\(dark ? "dark" : "light")")
        for _ in 0..<4 { closeTop(app) }
        app.buttons["Back"].tap()
        evidence(app, name: "session-settings-stack-retired")
    }

    @MainActor private func captureQueuedEditor(dark: Bool) {
        continueAfterFailure = false
        for removed in [false, true] {
            let args = ["-foreground-queued-editor"] + (removed ? ["-foreground-queued-removed"] : [])
            let app = launch(dark, arguments: args); defer { app.terminate() }
            app.buttons["home-pinned-row"].tap()
            let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Queued message 1607")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 20), app.debugDescription); row.tap()
            let editor = app.textViews["Queued message"]
            XCTAssertTrue(editor.waitForExistence(timeout: 20), app.debugDescription)
            editor.tap(); editor.typeText(" retained draft")
            capture(app, name: "queued-\(removed ? "removed" : "retained")-\(dark ? "dark" : "light")")
            if editor.exists {
                let title = app.navigationBars.staticTexts["Queued Message"].firstMatch
                title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
            }
            app.buttons["Back"].tap()
            evidence(app, name: "queued-stack-retired")
            app.terminate()
        }
    }

    @MainActor private func closeTop(_ app: XCUIApplication) {
        let done = app.buttons.matching(NSPredicate(format: "label == %@", "Done"))
            .allElementsBoundByIndex.first { $0.isHittable }
        guard let done else { return XCTFail("No top Done button: \(app.debugDescription)") }
        done.tap()
    }

    @MainActor private func markReveal(_ app: XCUIApplication, name: String) {
        let reads = app.staticTexts["fixture.home-read-counts"].firstMatch
        print("REVEAL_CAPTURE \(name) \(Date().timeIntervalSince1970) \(reads.exists ? reads.label : "no read label")")
        evidence(app, name: name)
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
