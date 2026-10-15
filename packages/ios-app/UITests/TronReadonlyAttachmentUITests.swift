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
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        // The lone inline image is the same thumbnail component grouped displays use.
        XCTAssertEqual(button.identifier, "display-inline-thumbnail")
        XCTAssertEqual(button.frame.width, 64 * 1.7, accuracy: 1)
        keepScreenshot(app, "998-inline-display-thumbnail")
        button.tap()
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
            assertGeneratedVideoEdge(in: app, player: sheetPlayer, scenario: scenario)

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
            assertGeneratedVideoEdge(in: app, player: sheetPlayer, scenario: scenario)
        }
    }

    /// #889: a displayed `.swift` file runs as a native, interactive app only
    /// behind the experimental flag.
    @MainActor func testDisplayedSwiftFileRunsAsInteractiveAppBehindExperimentFlag() {
        continueAfterFailure = false
        let app = launchSwift("display-swift", flag: true); defer { app.terminate() }
        openSwiftDisplay(app, named: "Habits.swift")
        let run = app.buttons["Run Habits.swift"]
        XCTAssertTrue(run.waitForExistence(timeout: 10), "The flag adds the run control to the .swift document sheet")
        keepScreenshot(app, "889-1-swift-source-sheet")
        run.tap()

        let summary = app.staticTexts["habits.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "The interpreted app renders natively")
        XCTAssertEqual(summary.label, "0 of 3 done today")
        XCTAssertTrue(app.staticTexts["4 day streak"].exists)
        keepScreenshot(app, "889-2-app-running")

        app.buttons["Complete Drink water"].tap()
        XCTAssertTrue(wait(summary, predicate: "label == '1 of 3 done today'"), "Button actions mutate interpreted @State through a @Binding")
        XCTAssertTrue(app.staticTexts["5 day streak"].waitForExistence(timeout: 5))

        app.segmentedControls.buttons["Done"].tap()
        XCTAssertTrue(wait(app.staticTexts["Read 20 pages"], predicate: "exists == false"), "The segmented Picker filters rows")
        XCTAssertTrue(app.staticTexts["Drink water"].exists)
        keepScreenshot(app, "889-3-app-filtered")
        app.segmentedControls.buttons["All"].tap()

        let field = app.textFields["Habit name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Meditate")
        app.buttons["Add"].tap()
        XCTAssertTrue(app.staticTexts["Meditate"].waitForExistence(timeout: 5), "TextField binding and array append work")
        XCTAssertTrue(wait(summary, predicate: "label == '1 of 4 done today'"))
        keepScreenshot(app, "889-4-app-after-add")
    }

    /// #889: without the flag a `.swift` display is an ordinary document
    /// sheet, and even with it a truncated preview never runs.
    @MainActor func testSwiftRunControlRequiresFlagAndCompletePreview() {
        continueAfterFailure = false
        // The flag is sticky across launches, so the control turns it off explicitly.
        let control = launchSwift("display-swift", flag: false); defer { control.terminate() }
        openSwiftDisplay(control, named: "Habits.swift")
        let done = control.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        XCTAssertFalse(runControl(control).exists, "Without the flag the shared document sheet has no run control")
        XCTAssertLessThan(done.frame.minY, control.windows.firstMatch.frame.height * 0.35, "The sheet keeps its large document detent")
        keepScreenshot(control, "889-0-flag-off-document-sheet")
        done.tap()
        XCTAssertTrue(wait(done, predicate: "exists == false"), "Done still dismisses the document sheet")
        control.terminate()

        let truncated = launchSwift("display-swift-truncated", flag: true)
        openSwiftDisplay(truncated, named: "Habits.swift")
        XCTAssertTrue(truncated.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Preview shows the first'")).firstMatch.waitForExistence(timeout: 10),
                      "The fixture is past the preview limit")
        XCTAssertFalse(runControl(truncated).exists, "A truncated preview never offers to run a partial program")
        keepScreenshot(truncated, "889-5-truncated-no-run")
    }

    /// #889: a second app style — a shared ObservableObject store passed
    /// through environmentObject, a TabView, Lists, an enum switch and
    /// String(format:) — keeps one store across tabs.
    @MainActor func testDisplayedSwiftStoreAppSharesStateAcrossTabs() {
        continueAfterFailure = false
        let app = launchSwift("display-swift-budget", flag: true); defer { app.terminate() }
        openSwiftDisplay(app, named: "Budget.swift")
        let run = app.buttons["Run Budget.swift"]
        XCTAssertTrue(run.waitForExistence(timeout: 10)); run.tap()

        XCTAssertTrue(app.staticTexts["Groceries"].waitForExistence(timeout: 10), "The App's WindowGroup renders the first tab")
        XCTAssertTrue(app.staticTexts["$42.50"].exists, "String(format:) formats currency")
        app.buttons["Add food"].tap()
        XCTAssertTrue(app.staticTexts["New food"].waitForExistence(timeout: 5), "A store method appends a @Published expense")
        XCTAssertTrue(app.staticTexts["$12.25"].exists)
        keepScreenshot(app, "889-6-budget-expenses")

        app.buttons["Summary"].tap()
        let total = app.staticTexts["budget.total"]
        XCTAssertTrue(total.waitForExistence(timeout: 5), "The TabView switches to the second tab")
        XCTAssertEqual(total.label, "Total $72.75 across 3 expenses", "The other tab reads the same environment object")
        XCTAssertEqual(app.staticTexts["budget.food"].label, "54.75")
        XCTAssertEqual(app.staticTexts["budget.travel"].label, "18.00")
        XCTAssertEqual(app.staticTexts["budget.fun"].label, "0.00")
        keepScreenshot(app, "889-7-budget-summary")

        // #1027: dismiss() closes the presentation the program created, and
        // only that: a pushed destination pops, a sheet closes after its save,
        // and in the program's root it never closes the runner itself.
        app.buttons["Biggest expense"].tap()
        let back = app.buttons["Back to summary"]
        XCTAssertTrue(back.waitForExistence(timeout: 5)); back.tap()
        XCTAssertTrue(wait(back, predicate: "exists == false"), "dismiss() pops the program's navigation destination")
        XCTAssertTrue(total.waitForExistence(timeout: 5))

        app.buttons["Expenses"].tap()
        XCTAssertTrue(app.staticTexts["New food"].waitForExistence(timeout: 5), "Switching tabs keeps the shared store")
        app.buttons["Plan trip"].tap()
        let save = app.buttons["Save trip"]
        XCTAssertTrue(save.waitForExistence(timeout: 5)); save.tap()
        XCTAssertTrue(wait(save, predicate: "exists == false"), "dismiss() closes the program's own sheet")
        XCTAssertTrue(app.staticTexts["New travel"].waitForExistence(timeout: 5), "The sheet's action ran before it closed")
        keepScreenshot(app, "1027-sheet-dismissed")

        app.buttons["Leave app"].tap()
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(app.staticTexts["New travel"].exists, "dismiss() in the program's root never closes the runner sheet")
    }

    /// #889: unsupported Swift shows a line-numbered diagnostic; runaway loops,
    /// recursion and growth stop at the runtime limits; hostile arithmetic,
    /// formats and self-containing views cannot crash the app, which stays
    /// responsive throughout.
    @MainActor func testSwiftAppFailuresStayContainedInTheRunner() {
        continueAfterFailure = false
        let broken = launchSwift("display-swift-broken", flag: true); defer { broken.terminate() }
        openSwiftDisplay(broken, named: "Broken.swift")
        let runBroken = broken.buttons["Run Broken.swift"]
        XCTAssertTrue(runBroken.waitForExistence(timeout: 10)); runBroken.tap()
        let unsupported = broken.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Line 4: Dictionaries are not supported'")).firstMatch
        XCTAssertTrue(unsupported.waitForExistence(timeout: 10), "Unsupported syntax names its line instead of running")
        keepScreenshot(broken, "889-8-unsupported-syntax")
        broken.terminate()

        // Nesting deep enough to overflow a recursive parser stops at the parser limit.
        let deep = launchSwift("display-swift-deep", flag: true)
        openSwiftDisplay(deep, named: "Deep.swift")
        let runDeep = deep.buttons["Run Deep.swift"]
        XCTAssertTrue(runDeep.waitForExistence(timeout: 10)); runDeep.tap()
        XCTAssertTrue(deep.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Line 3: Code is nested too deeply'")).firstMatch.waitForExistence(timeout: 10))
        deep.terminate()

        let app = launchSwift("display-swift-limits", flag: true)
        openSwiftDisplay(app, named: "Limits.swift")
        let run = app.buttons["Run Limits.swift"]
        XCTAssertTrue(run.waitForExistence(timeout: 10)); run.tap()
        let taps = app.staticTexts["limits.taps"]
        XCTAssertTrue(taps.waitForExistence(timeout: 10))
        XCTAssertTrue(diagnostic(app, "Line 62: Unknown name 'Map'").exists, "An unsupported view renders an inline diagnostic beside working views")

        var expectedTaps = 0
        for (button, message) in [
            ("Loop forever", "ran too long"),
            ("Recurse forever", "recursion is too deep"),
            ("Grow forever", "string grew past"),
            ("Read itself", "recursion is too deep"),
            ("Overflow", "Integer overflow"),
            // 2^40 shared leaves: comparison is budgeted, not exponential.
            ("Compare shared", "ran too long"),
        ] {
            app.buttons[button].tap()
            XCTAssertTrue(diagnostic(app, message).waitForExistence(timeout: 15), "\(button) stops with a diagnostic")
            keepScreenshot(app, "889-9-\(button)")
            app.buttons["Count"].tap()
            expectedTaps += 1
            XCTAssertTrue(wait(taps, predicate: "label == %@", value: "Taps: \(expectedTaps)"), "The app stays responsive after \(button)")
            XCTAssertTrue(wait(diagnostic(app, message), predicate: "exists == false"), "A successful action clears the diagnostic")
        }

        // A program-chosen format never reaches Foundation with a mismatched
        // argument: %s and %@ print the value instead of reading memory.
        app.buttons["Hostile format"].tap()
        XCTAssertTrue(wait(app.staticTexts["limits.note"], predicate: "label == %@", value: "\(expectedTaps)|2.5|  3.0"))

        // Describing the same shared value is bounded, not 2^40 elements long.
        app.buttons["Describe shared"].tap()
        XCTAssertTrue(wait(app.staticTexts["limits.note"], predicate: "label BEGINSWITH '[[[[' AND label ENDSWITH '…'"))

        app.buttons["Nest views"].tap()
        XCTAssertTrue(diagnostic(app, "views are nested too deeply").waitForExistence(timeout: 15), "A view that contains itself stops at the depth limit")
        keepScreenshot(app, "889-9-Nest views")
        app.buttons["Count"].tap()
        XCTAssertTrue(wait(taps, predicate: "label == %@", value: "Taps: \(expectedTaps + 1)"), "The app stays responsive after nesting views")
    }

    /// #1006: the Settings › Tools & Diagnostics › Experimental switch turns the run
    /// control on and off live, without a relaunch, and it wins over the
    /// launch argument that started this process with the runner off.
    @MainActor func testSettingsSwitchAddsAndRemovesSwiftRunControlLive() {
        continueAfterFailure = false
        let app = launchSwift("display-swift-settings", flag: false); defer { app.terminate() }
        openSwiftDisplay(app, named: "Habits.swift")
        XCTAssertFalse(runControl(app).exists, "The runner starts off")
        closeDocument(app)

        setSwiftRunner(app, on: true)
        openSwiftDisplay(app, named: "Habits.swift")
        let run = app.buttons["Run Habits.swift"]
        XCTAssertTrue(run.waitForExistence(timeout: 10), "Turning the switch on adds the run control without a relaunch")
        keepScreenshot(app, "1006-3-run-control-after-switch-on")
        run.tap()
        XCTAssertTrue(app.staticTexts["habits.summary"].waitForExistence(timeout: 10), "The run control runs the app")
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(wait(app.staticTexts["habits.summary"], predicate: "exists == false"))
        closeDocument(app)

        setSwiftRunner(app, on: false)
        openSwiftDisplay(app, named: "Habits.swift")
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10))
        XCTAssertFalse(runControl(app).exists, "Turning the switch off removes the run control")
        keepScreenshot(app, "1006-4-run-control-after-switch-off")
    }

    @MainActor private func setSwiftRunner(_ app: XCUIApplication, on: Bool) {
        let open = app.buttons["fixture.open-settings"]
        XCTAssertTrue(open.waitForExistence(timeout: 10)); open.tap()
        let experimental = app.buttons["settings-link-Experimental"]
        XCTAssertTrue(experimental.waitForExistence(timeout: 10))
        for _ in 0..<12 where !experimental.isHittable { app.swipeUp() }
        keepScreenshot(app, "1006-1-settings-tools-diagnostics")
        experimental.tap()
        let toggle = app.switches["settings-experimental-swift-apps"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), app.debugDescription)
        if (toggle.value as? String == "1") != on { toggle.tap() }
        XCTAssertTrue(wait(toggle, predicate: "value == %@", value: on ? "1" : "0"), "The switch shows the new state")
        keepScreenshot(app, "1006-2-experimental-\(on ? "on" : "off")")
        app.buttons.matching(NSPredicate(format: "label == 'Done'")).allElementsBoundByIndex.last(where: \.isHittable)?.tap()
        XCTAssertTrue(wait(toggle, predicate: "exists == false"), "Experimental is dismissed")
        app.buttons["settings-done"].tap()
        XCTAssertTrue(wait(app.buttons["settings-done"], predicate: "exists == false"), "Settings is dismissed")
    }

    @MainActor private func closeDocument(_ app: XCUIApplication) {
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10)); done.tap()
        XCTAssertTrue(wait(done, predicate: "exists == false"))
    }

    @MainActor private func launchSwift(_ scenario: String, flag: Bool) -> XCUIApplication {
        launch(scenario, extraArguments: ["-tron.experimental.swiftApps", flag ? "YES" : "NO"])
    }

    @MainActor private func runControl(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Run '")).firstMatch
    }

    @MainActor private func diagnostic(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @MainActor private func openSwiftDisplay(_ app: XCUIApplication, named name: String) {
        let display = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        XCTAssertTrue(display.waitForExistence(timeout: 15)); display.tap()
        let reader = app.textViews.matching(NSPredicate(format: "value BEGINSWITH 'import SwiftUI'")).firstMatch
        XCTAssertTrue(reader.waitForExistence(timeout: 10), "The .swift source is shown in the shared document sheet")
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

    @MainActor private func launch(_ scenario: String, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-readonly-attachment-fixture", "-readonly-preview-scenario", scenario, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extraArguments
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
    @MainActor private func assertGeneratedVideoEdge(
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
        let fittedOrigin = CGPoint(
            x: viewport.minX + (viewport.width - fittedSide) / 2,
            y: viewport.minY + (viewport.height - fittedSide) / 2
        )
        let screenFrame = app.frame
        let yPoint = fittedOrigin.y + fittedSide * 0.05
        let sample = { (xPoint: CGFloat) -> (Int, Int, Int)? in
            let x = Int((xPoint - screenFrame.minX) * CGFloat(image.width) / screenFrame.width)
            let y = Int((yPoint - screenFrame.minY) * CGFloat(image.height) / screenFrame.height)
            guard x >= 0, x < image.width, y >= 0, y < image.height,
                  let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
            var rgba = [UInt8](repeating: 0, count: 4)
            let color = rgba.withUnsafeMutableBytes { buffer -> (Int, Int, Int)? in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                ) else { return nil }
                context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                return (Int(buffer[0]), Int(buffer[1]), Int(buffer[2]))
            }
            return color
        }
        // The generated clip is cyan on the left and magenta on the right. The
        // matched pair sits in the top band, where title-blur underlap occurred.
        let delta = max(fittedSide * 0.01, 1)
        guard let left = sample(viewport.midX - delta), let right = sample(viewport.midX + delta) else {
            XCTFail("\(scenario): video edge samples are outside the captured viewport", file: file, line: line)
            return
        }
        let contrast = abs(left.0 - right.0) + abs(left.1 - right.1) + abs(left.2 - right.2)
        XCTAssertGreaterThan(contrast, 180, "\(scenario): the distinct video edge must remain visible; RGB samples \(left) and \(right) differ by only \(contrast)", file: file, line: line)
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
