import XCTest

/// Sheet behavior through the production views and hosted Gateway socket.
/// Captures are attachments for maintainer review, not golden comparisons.
@MainActor final class TronSheetLayoutUITests: XCTestCase {
    func testHomeSettingsAreOnMainSheet() {
        let app = home()
        defer { app.terminate() }
        XCTAssertFalse(app.buttons["settings-section-model-open"].exists, "Workers are edited on Home Settings")
        XCTAssertFalse(app.buttons["settings-section-tools-open"].exists, "The Tools setting is on Home Settings")
        XCTAssertFalse(app.buttons["settings-section-advanced-open"].exists, "Connection and approvals are on Home Settings")
        for prefix in ["settings-row-model.queue_role_worker_", "settings-row-model.queue_role_subagent_", "settings-row-model.queue_role_background_", "settings-row-tools.active", "settings-row-run.transport", "settings-row-run.retry.maxRetries"] {
            let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT identifier ENDSWITH '-reset'", prefix)).firstMatch
            XCTAssertTrue(row.exists, "Inline setting \(prefix)\n\(app.debugDescription)")
        }
        XCTAssertTrue(app.staticTexts["Home's overrides of Global settings. Worker launch choices apply to new workers."].exists)
        // Revert and list editing retain their independent shared controls.
        let worker = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'settings-row-model.queue_role_worker_' AND NOT identifier ENDSWITH '-reset'")).firstMatch
        XCTAssertTrue(worker.staticTexts["Overridden"].exists)
        XCTAssertTrue(worker.buttons.matching(NSPredicate(format: "identifier ENDSWITH '-reset'")).firstMatch.exists)
        let editor = worker.buttons["Worker models"].firstMatch
        reveal(editor, in: app)
        editor.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Worker models"].waitForExistence(timeout: 8), "The existing deeper list editor still opens")
    }

    func testSessionCaptionFollowsUntitledSettingsCard() {
        let app = session()
        defer { app.terminate() }
        XCTAssertFalse(app.staticTexts["Settings"].exists, "No Settings heading above the session card")
        let tools = app.buttons["settings-section-tools-open"]
        let trust = app.buttons["project-settings-trust"]
        let caption = app.staticTexts["Choices for this session. Revert an override to use Global settings."]
        XCTAssertTrue(tools.exists && trust.exists && caption.exists, app.debugDescription)
        XCTAssertGreaterThan(caption.frame.minY, max(tools.frame.maxY, trust.frame.maxY), "The explanatory caption is the card's footer")
        XCTAssertLessThan(caption.frame.minY, app.staticTexts["Repository Overrides"].frame.minY, "The footer belongs to session choices, not repository overrides")
    }

    func testHistoryEntryUsesOneScrollAndClearsToolbarAtMedium() {
        let app = history()
        defer { app.terminate() }
        let title = app.navigationBars.staticTexts["History Entry"].firstMatch
        let done = app.navigationBars.containing(.staticText, identifier: "History Entry").buttons["Done"].firstMatch
        let response = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Response'")).firstMatch
        XCTAssertTrue(response.exists, app.debugDescription)
        XCTAssertGreaterThan(title.frame.minY, app.windows.firstMatch.frame.height * 0.35, "Exercise the medium detent")
        XCTAssertGreaterThanOrEqual(response.frame.minY, done.frame.maxY, "The top card must not overlap the toolbar")
        let reader = app.scrollViews.matching(NSPredicate(format: "identifier == 'history-entry-scroll'")).firstMatch
        XCTAssertTrue(reader.exists, "One sheet-level reader owns scrolling")
        XCTAssertEqual(reader.scrollViews.count, 0, "No nested scroll view")
        XCTAssertEqual(reader.textViews.count, 0, "No independently scrolling UITextView")
        let actions = app.descendants(matching: .any)["history-entry-actions"].firstMatch
        let initialY = response.frame.minY
        reader.swipeUp()
        XCTAssertLessThan(response.frame.minY, initialY, "The top card and content flow together")
        XCTAssertTrue(actions.exists, "Actions remain in the sheet")
    }

    /// At XXXL a shared row's title keeps the full text width and its Overridden
    /// pill moves below it, instead of the title shrinking to a fragment.
    func testSharedRowTitleKeepsFullWidthAtXXXL() {
        let app = home(xxxl: true)
        defer { app.terminate() }
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'settings-row-model.queue_role_worker_' AND NOT identifier ENDSWITH '-reset'")).firstMatch
        XCTAssertTrue(row.exists, app.debugDescription)
        let title = row.staticTexts["Worker models"].firstMatch
        let pill = row.staticTexts["Overridden"].firstMatch
        XCTAssertTrue(title.exists && pill.exists, row.debugDescription)
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(title.frame.width, window.width * 0.4, "The title is not squeezed beside its pill: \(title.frame)")
        XCTAssertGreaterThanOrEqual(pill.frame.minY, title.frame.maxY - 1, "The pill stacks below the title: \(pill.frame) vs \(title.frame)")
    }

    func testCaptureXXXLHome() { for dark in [false, true] { let app = home(dark: dark, xxxl: true); shot("xxxl-home-\(dark ? "dark" : "light")"); app.swipeUp(); shot("xxxl-home-\(dark ? "dark" : "light")-scrolled"); app.terminate() } }
    func testCaptureXXXLSessionSettings() { for dark in [false, true] { let app = session(dark: dark, xxxl: true); shot("xxxl-session-settings-\(dark ? "dark" : "light")"); app.terminate() } }
    func testCaptureXXXLSessionMoreSettings() {
        for dark in [false, true] {
            let app = session(dark: dark, xxxl: true)
            let more = app.buttons["settings-section-advanced-open"]
            reveal(more, in: app)
            more.tap()
            expand(app, title: "More Settings")
            shot("xxxl-more-settings-\(dark ? "dark" : "light")")
            app.terminate()
        }
    }
    func testCaptureXXXLManageSession() { for dark in [false, true] { let app = sessionApp(dark: dark, xxxl: true); shot("xxxl-manage-session-\(dark ? "dark" : "light")"); app.terminate() } }

    func testCaptureHomeLightNormal() { captureHome(dark: false, xxxl: false) }
    func testCaptureHomeDarkNormal() { captureHome(dark: true, xxxl: false) }
    func testCaptureHomeLightXXXL() { captureHome(dark: false, xxxl: true) }
    func testCaptureHomeDarkXXXL() { captureHome(dark: true, xxxl: true) }
    func testCaptureSessionLight() { let app = session(); defer { app.terminate() }; shot("session-light") }
    func testCaptureSessionDark() { let app = session(dark: true); defer { app.terminate() }; shot("session-dark") }
    func testCaptureHistoryLight() { captureHistory(dark: false) }
    func testCaptureHistoryDark() { captureHistory(dark: true) }

    private func captureHome(dark: Bool, xxxl: Bool) {
        let app = home(dark: dark, xxxl: xxxl)
        defer { app.terminate() }
        let name = "home-\(dark ? "dark" : "light")-\(xxxl ? "xxxl" : "normal")"
        shot("\(name)-top")
        for index in 1...5 {
            app.swipeUp()
            shot("\(name)-scroll-\(index)")
        }
    }

    private func captureHistory(dark: Bool) {
        let app = history(dark: dark)
        defer { app.terminate() }
        let mode = dark ? "dark" : "light"
        shot("history-\(mode)-medium")
        expand(app, title: "History Entry")
        shot("history-\(mode)-large")
        app.swipeUp()
        shot("history-\(mode)-large-scrolled")
    }

    private func home(dark: Bool = false, xxxl: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-settings-scope-review"] + (dark ? ["-home-dark"] : [])
        if xxxl { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"] }
        app.launch()
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 15))
        app.buttons["home-pinned-row"].tap()
        let ring = app.buttons["session-context-button"]
        XCTAssertTrue(ring.waitForExistence(timeout: 15))
        XCTAssertTrue(wait(ring, "enabled == true"))
        ring.tap()
        let row = app.descendants(matching: .any)["home-manage-settings"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), app.debugDescription)
        reveal(row, in: app)
        row.tap()
        expand(app, title: "Home Settings")
        return app
    }

    private func session(dark: Bool = false, xxxl: Bool = false) -> XCUIApplication {
        let app = sessionApp(dark: dark, xxxl: xxxl)
        let link = app.buttons["chat-settings-link"]
        reveal(link, in: app)
        link.tap()
        expand(app, title: "Session Settings")
        return app
    }

    private func history(dark: Bool = false) -> XCUIApplication {
        let app = sessionApp(dark: dark, extra: ["-manage-session-review", "-history-large"])
        let link = app.buttons["Session History"]
        reveal(link, in: app)
        link.tap()
        XCTAssertTrue(app.buttons["history-row-h-6732"].waitForExistence(timeout: 10), app.debugDescription)
        expand(app, title: "Session History")
        app.buttons["history-row-h-6731"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["History Entry"].waitForExistence(timeout: 8), app.debugDescription)
        // Wait for the actual content load before sampling the medium-detent layout.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ENDSWITH ' characters'")).firstMatch.waitForExistence(timeout: 8), app.debugDescription)
        return app
    }

    private func sessionApp(dark: Bool, xxxl: Bool = false, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-configuration-fixture", "-settings-scope-review", "-fixture-appearance", dark ? "dark" : "light"] + extra
        if xxxl { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"] }
        app.launch()
        XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 10))
        app.buttons["Stop session"].tap()
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }

    private func expand(_ app: XCUIApplication, title text: String) {
        let title = app.navigationBars.staticTexts[text].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 8), app.debugDescription)
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        for _ in 0..<3 where title.frame.minY > 120 {
            origin.withOffset(CGVector(dx: 60, dy: title.frame.midY))
                .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: 60, dy: 20)))
            _ = wait(title, "frame.minY < 120", timeout: 2)
        }
    }

    private func wait(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 10) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)], timeout: timeout) == .completed
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
