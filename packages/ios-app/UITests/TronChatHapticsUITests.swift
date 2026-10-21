import XCTest

/// Chat haptics (#1562) and sheet presentation haptics (#1599), read from the
/// hosted probe of every haptic the app played (XCUITest cannot feel the
/// Taptic Engine). The fixtures are the real chat route, composer and
/// attachment strip, and the real Settings root, over scripted Gateways.
final class TronChatHapticsUITests: XCTestCase {
    /// Each live event plays its own haptic exactly once: one tick per pasted
    /// photo, the accepted send, the settled run, a worker result and a
    /// presented question. A rejected send, a re-presented or answered
    /// question and a stopped run play none.
    @MainActor func testLiveEventsPlayTheirHapticOnce() {
        continueAfterFailure = false
        let app = launch(photos: 3); defer { app.terminate() }
        let composer = openComposer(app)
        paste(app, into: composer)
        XCTAssertTrue(waitHaptics(app, "attachmentAdded,attachmentAdded,attachmentAdded"), haptics(app))

        send("hello", app, composer)
        XCTAssertTrue(waitHaptics(app, "attachmentAdded,attachmentAdded,attachmentAdded,promptSent,runFinished"),
                      "the accepted send taps, then the settled run completes: \(haptics(app))")
        var expected = "attachmentAdded,attachmentAdded,attachmentAdded,promptSent,runFinished"

        app.buttons["fixture.deliver-worker"].tap()
        expected += ",workerMessage"
        XCTAssertTrue(waitHaptics(app, expected), "a worker result plays its own haptic: \(haptics(app))")

        app.buttons["fixture.ask-question"].tap()
        expected += ",questionPresented"
        let cancel = app.buttons["Cancel form"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(waitHaptics(app, expected), "the question sheet plays one attention haptic: \(haptics(app))")
        keep(app, "1562-question-presented")

        // Reopening the chat presents the still-pending question again, silently.
        app.buttons["fixture.reopen-chat"].tap()
        XCTAssertTrue(cancel.waitForExistence(timeout: 20), app.debugDescription)
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 10), app.debugDescription)
        let answered = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Ask User")).firstMatch
        XCTAssertTrue(answered.waitForExistence(timeout: 10), app.debugDescription)
        answered.tap()
        XCTAssertTrue(app.staticTexts["Cancelled — no answers submitted"].waitForExistence(timeout: 10), app.debugDescription)
        keep(app, "1562-answered-question-read-only")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForNonExistence(timeout: 10), app.debugDescription)
        // The answered question's tool sheet is an ordinary sheet: one soft tap (#1599).
        expected += ",sheetPresented"
        assertHaptics(app, expected, "re-presenting and answering the question play nothing; its tool sheet taps once")

        send("fail", app, composer)
        XCTAssertTrue(waitGateway(app, "rejected:1"), gateway(app))
        assertHaptics(app, expected, "a rejected send plays nothing")

        // The rejected draft is restored, so this sends it with `slow` added.
        send("slow", app, composer)
        expected += ",promptSent"
        XCTAssertTrue(waitGateway(app, "phase:running"), gateway(app))
        XCTAssertTrue(waitHaptics(app, expected), haptics(app))
        let stop = app.buttons["Stop Tron"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10), app.debugDescription)
        stop.tap()
        XCTAssertTrue(waitGateway(app, "aborts:1"), gateway(app))
        XCTAssertTrue(waitGateway(app, "phase:idle"), gateway(app))
        assertHaptics(app, expected, "a stopped run plays no completion")
    }

    /// One photo is one tick; a large batch caps at six ticks.
    @MainActor func testAttachmentTicksAreOnePerPhotoAndCapped() {
        continueAfterFailure = false
        for (photos, ticks) in [(1, 1), (9, 6)] {
            let app = launch(photos: photos); defer { app.terminate() }
            paste(app, into: openComposer(app))
            let expected = Array(repeating: "attachmentAdded", count: ticks).joined(separator: ",")
            XCTAssertTrue(waitHaptics(app, expected), "\(photos) photo(s): \(haptics(app))")
            assertHaptics(app, expected, "\(photos) photo(s) tick \(ticks) time(s)")
        }
    }

    /// History already holding a finished run, a worker result and a pending
    /// question plays nothing when the chat opens, and a run that settles
    /// while the app is in the background plays nothing on return.
    @MainActor func testRestoredAndBackgroundEventsPlayNone() {
        continueAfterFailure = false
        let app = launch(photos: 0, ["-chat-haptics-history"]); defer { app.terminate() }
        let cancel = app.buttons["Cancel form"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 30), app.debugDescription)
        keep(app, "1562-restored-question")
        assertHaptics(app, "none", "a restored run, worker result and pending question play nothing")
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 10), app.debugDescription)

        let composer = app.textViews["Message input"]
        send("away", app, composer)
        XCTAssertTrue(waitHaptics(app, "promptSent"), haptics(app))
        XCUIDevice.shared.press(.home)
        sleep(5)
        app.activate()
        XCTAssertTrue(waitGateway(app, "phase:idle"), gateway(app))
        XCTAssertTrue(composer.waitForExistence(timeout: 20), app.debugDescription)
        assertHaptics(app, "promptSent", "a run settled in the background plays nothing on return")
    }

    /// A tool detail sheet plays one soft tap per presentation (#1599), never
    /// on dismissal, and the restored question beneath it plays nothing.
    @MainActor func testToolSheetPlaysOneSoftTapPerPresentation() {
        continueAfterFailure = false
        let app = launch(photos: 0, ["-chat-haptics-history"]); defer { app.terminate() }
        let cancel = app.buttons["Cancel form"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 30), app.debugDescription)
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 10), app.debugDescription)
        assertHaptics(app, "none", "the restored question and its dismissal play nothing")
        let tool = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Ask User")).firstMatch
        var expected: [String] = []
        for _ in 0..<2 {
            XCTAssertTrue(tool.waitForExistence(timeout: 10), app.debugDescription)
            tool.tap()
            XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10), app.debugDescription)
            expected.append("sheetPresented")
            XCTAssertTrue(waitHaptics(app, expected.joined(separator: ",")), haptics(app))
            app.buttons["Done"].tap()
            XCTAssertTrue(app.buttons["Done"].waitForNonExistence(timeout: 10), app.debugDescription)
            assertHaptics(app, expected.joined(separator: ","), "dismissing the tool sheet plays nothing")
        }
        keep(app, "1599-tool-sheet")
    }

    /// A Settings section sheet and the Value & Source sheet nested on it each
    /// play one soft tap per presentation (#1599); a detent change and each
    /// dismissal play nothing.
    @MainActor func testSettingsAndNestedSheetsPlayOneSoftTapEach() {
        continueAfterFailure = false
        let app = launchSettings(["-settings-renderer-source-actions"]); defer { app.terminate() }
        let section = app.buttons["settings-section-model-open"]
        XCTAssertTrue(section.waitForExistence(timeout: 30), app.debugDescription)
        assertHaptics(app, "none", "the Settings root presents no sheet")
        section.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings-section-model-detail"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(waitHaptics(app, "sheetPresented"), haptics(app))

        let heading = app.navigationBars.staticTexts["Models"].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 5), app.debugDescription)
        heading.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)))
        assertHaptics(app, "sheetPresented", "expanding the sheet's detent plays nothing")

        let source = app.buttons["settings-row-model.ref-source"]
        XCTAssertTrue(source.waitForExistence(timeout: 10), app.debugDescription)
        source.tap()
        XCTAssertTrue(app.staticTexts["Value & Source"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(waitHaptics(app, "sheetPresented,sheetPresented"), "the nested sheet taps once: \(haptics(app))")
        keep(app, "1599-nested-sheet")
        closeTopSheet(app)
        XCTAssertTrue(app.staticTexts["Value & Source"].waitForNonExistence(timeout: 10), app.debugDescription)
        assertHaptics(app, "sheetPresented,sheetPresented", "dismissing the nested sheet plays nothing")

        source.tap()
        XCTAssertTrue(app.staticTexts["Value & Source"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(waitHaptics(app, "sheetPresented,sheetPresented,sheetPresented"), haptics(app))
        closeTopSheet(app)
        closeTopSheet(app)
        XCTAssertTrue(section.waitForExistence(timeout: 10), app.debugDescription)
        assertHaptics(app, "sheetPresented,sheetPresented,sheetPresented", "dismissing both sheets plays nothing")
    }

    /// A sheet already presented when its shared presenter mounts (as on
    /// launch, reconnect or a rebuilt parent) plays nothing, nor does its
    /// dismissal (#1599).
    @MainActor func testSheetPresentedAtMountPlaysNone() {
        continueAfterFailure = false
        let app = launchSettings(["-sheet-haptics-restored"]); defer { app.terminate() }
        XCTAssertTrue(app.buttons["Release preview"].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.staticTexts["fixture.haptics"].waitForExistence(timeout: 30), app.debugDescription)
        keep(app, "1599-restored-sheet")
        assertHaptics(app, "none", "a sheet presented at mount plays nothing")
        closeTopSheet(app)
        XCTAssertTrue(app.buttons["Release preview"].waitForNonExistence(timeout: 10), app.debugDescription)
        assertHaptics(app, "none", "its dismissal plays nothing")
    }

    // MARK: - Helpers

    @MainActor private func launchSettings(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extra
        app.launch()
        return app
    }

    /// Dismisses the frontmost sheet by its own Done; covered sheets' Done
    /// buttons are not hittable.
    @MainActor private func closeTopSheet(_ app: XCUIApplication) {
        let done = app.buttons.matching(NSPredicate(format: "label == %@", "Done")).allElementsBoundByIndex.last { $0.isHittable }
        XCTAssertNotNil(done, app.debugDescription)
        done?.tap()
    }

    @MainActor private func launch(photos: Int, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-chat-haptics-fixture", "-chat-haptics-photos", "\(photos)",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extra
        app.launch()
        return app
    }

    @MainActor private func openComposer(_ app: XCUIApplication) -> XCUIElement {
        let composer = app.textViews["Message input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(waitGateway(app, "opens:1"), gateway(app))
        assertHaptics(app, "none", "opening the chat plays nothing")
        return composer
    }

    @MainActor private func paste(_ app: XCUIApplication, into composer: XCUIElement) {
        composer.tap()
        let paste = app.menuItems["Paste"]
        for _ in 0..<3 where !paste.exists {
            composer.press(forDuration: 1.0)
            if paste.waitForExistence(timeout: 3) { break }
        }
        XCTAssertTrue(paste.exists, "the composer edit menu offers Paste: \(app.debugDescription)")
        paste.tap()
    }

    @MainActor private func send(_ text: String, _ app: XCUIApplication, _ composer: XCUIElement) {
        composer.tap()
        composer.typeText(text)
        let send = app.buttons["Send message"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: send)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 20), .completed, app.debugDescription)
        send.tap()
    }

    @MainActor private func haptics(_ app: XCUIApplication) -> String { app.staticTexts["fixture.haptics"].label }
    @MainActor private func gateway(_ app: XCUIApplication) -> String { app.staticTexts["fixture.gateway"].label }

    @MainActor private func waitHaptics(_ app: XCUIApplication, _ played: String) -> Bool {
        wait(app.staticTexts["fixture.haptics"], NSPredicate(format: "label == %@", "haptics:\(played)"))
    }

    @MainActor private func waitGateway(_ app: XCUIApplication, _ fragment: String) -> Bool {
        wait(app.staticTexts["fixture.gateway"], NSPredicate(format: "label CONTAINS %@", fragment))
    }

    /// Holds long enough for a late or duplicate haptic to show.
    @MainActor private func assertHaptics(_ app: XCUIApplication, _ played: String, _ message: String) {
        sleep(2)
        XCTAssertEqual(haptics(app), "haptics:\(played)", message)
    }

    private func wait(_ element: XCUIElement, _ predicate: NSPredicate, timeout: TimeInterval = 20) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    @MainActor private func keep(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
        let text = XCTAttachment(string: haptics(app))
        text.name = "\(name)-haptics"; text.lifetime = .keepAlways; add(text)
    }
}
