import XCTest

/// Real shared controls and copy surfaces. The hosted probe observes semantic
/// output, while values/clipboard affordances prove the interaction occurred.
final class TronInteractionHapticsUITests: XCTestCase {
    @MainActor func testControlsTickOnlyOnDeliberateChanges() {
        continueAfterFailure = false
        let app = launch(); defer { app.terminate() }
        assertHaptics(app, "none")
        XCTAssertFalse(app.switches["Unavailable"].isEnabled)
        app.switches["Enabled"].tap()
        XCTAssertTrue(app.staticTexts["fixture.values"].label.contains("enabled:true"))
        assertHaptics(app, "toggleChanged")
        app.buttons["Restore values"].tap()
        assertHaptics(app, "toggleChanged")

        app.buttons["Choice"].tap()
        app.buttons["settings-option-First"].tap()
        assertHaptics(app, "toggleChanged,sheetPresented")
        app.buttons["Choice"].tap()
        app.buttons["settings-option-Second"].tap()
        XCTAssertTrue(app.staticTexts["fixture.values"].label.contains("choice:Second"))
        assertHaptics(app, "toggleChanged,sheetPresented,sheetPresented,selectionChanged")

        app.buttons["Checklist"].tap()
        app.buttons["settings-option-Second"].tap()
        app.buttons["settings-option-First"].tap()
        let save = app.buttons["Save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.staticTexts["fixture.values"].label.contains("selected:Second"))
        assertHaptics(app, "toggleChanged,sheetPresented,sheetPresented,selectionChanged,sheetPresented,selectionChanged,selectionChanged")
        app.buttons["Restore values"].tap()
        app.scrollViews.firstMatch.swipeUp()
        app.scrollViews.firstMatch.swipeDown()
        assertHaptics(app, "toggleChanged,sheetPresented,sheetPresented,selectionChanged,sheetPresented,selectionChanged,selectionChanged")
    }

    @MainActor func testCopyFeedbackOnlyWhenCopyCommits() {
        continueAfterFailure = false
        let app = launch(); defer { app.terminate() }
        app.buttons["Copy"].tap()
        XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 5))
        assertHaptics(app, "copied")
        app.staticTexts["fixture.copy-message"].press(forDuration: 1)
        let copy = app.buttons["Copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5), app.debugDescription)
        assertHaptics(app, "copied")
        copy.tap()
        assertHaptics(app, "copied,copied")
    }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-interaction-haptics-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.staticTexts["fixture.haptics"].waitForExistence(timeout: 20))
        return app
    }

    @MainActor private func assertHaptics(_ app: XCUIApplication, _ expected: String) {
        let probe = app.staticTexts["fixture.haptics"]
        let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "haptics:\(expected)"), object: probe)
        XCTAssertEqual(XCTWaiter.wait(for: [match], timeout: 5), .completed, probe.label)
        sleep(1)
        XCTAssertEqual(probe.label, "haptics:\(expected)", "No late/duplicate feedback")
    }
}
