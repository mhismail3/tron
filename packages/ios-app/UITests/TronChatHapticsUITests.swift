import XCTest

/// Chat haptics (#1562), read from the hosted probe of every haptic the app
/// played (XCUITest cannot feel the Taptic Engine). The fixture is the real
/// chat route, composer and attachment strip over a scripted Gateway.
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
        assertHaptics(app, expected, "re-presenting, answering and reopening the answered question play nothing")

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

    // MARK: - Helpers

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
