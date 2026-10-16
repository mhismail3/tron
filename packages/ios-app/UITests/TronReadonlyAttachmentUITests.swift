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
        let genericCount = app.staticTexts["habits.generic-count"]
        XCTAssertTrue(genericCount.waitForExistence(timeout: 5), "Generic custom views render with dynamically erased type parameters")
        XCTAssertEqual(genericCount.label, "Generic count: 0; array: 0", "A forward-declared explicit specialization and Array<Int>() both execute dynamically")
        let genericComparison = app.staticTexts["habits.generic-comparison"]
        XCTAssertEqual(genericComparison.label, "Less than one: true", "The comparison operator remains an expression, not a generic clause")
        XCTAssertTrue(app.staticTexts["4 day streak"].exists)
        keepScreenshot(app, "889-2-app-running")
        // #909: the runner hosts the program in the shared document sheet
        // chrome. The program's root navigationTitle is the shared sheet title
        // and Done is inked in that title's tint (TronSheetTitle +
        // tronToolbarAction); a runner with its own chrome fails here.
        assertToolbarTint(app, title: "Habits")

        app.buttons["Complete Drink water"].tap()
        XCTAssertTrue(wait(summary, predicate: "label == '1 of 3 done today'"), "Button actions mutate interpreted @State through a @Binding")
        XCTAssertTrue(wait(genericCount, predicate: "label == 'Generic count: 1; array: 0'"), "The generic custom view rerenders after its dynamic value changes")
        XCTAssertTrue(wait(genericComparison, predicate: "label == 'Less than one: false'"), "A less-than expression still evaluates after state changes")
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

        // #909: the shared Done closes the runner, back to the document sheet.
        app.navigationBars.containing(.staticText, identifier: "Habits").buttons["Done"].firstMatch.tap()
        XCTAssertTrue(wait(summary, predicate: "exists == false"), "Done closes the runner")
        XCTAssertTrue(run.waitForExistence(timeout: 5), "Closing the runner returns to the .swift document sheet")
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

    /// #1136: erased protocol requirements dispatch concrete existential values;
    /// native geometry updates on resize and exposes no writable/global proxy.
    @MainActor func testDisplayedSwiftProtocolsAndGeometryUseConcreteValues() {
        continueAfterFailure = false
        let app = launchSwift("display-swift-type-features", flag: true); defer { app.terminate() }
        openSwiftDisplay(app, named: "Shapes.swift")
        app.buttons["Run Shapes.swift"].tap()
        let dispatch = app.staticTexts["types.dispatch"]
        XCTAssertTrue(dispatch.waitForExistence(timeout: 10))
        XCTAssertEqual(dispatch.label, "Square, Rectangle: 34; optional 9")
        let geometry = app.staticTexts["types.geometry"]
        XCTAssertTrue(wait(geometry, predicate: "label == '120 x 180; local 0/120; equal true'"), geometry.label)
        let observations = app.staticTexts["types.observations"]
        let previous = observations.label
        app.buttons["Resize geometry"].tap()
        XCTAssertTrue(wait(geometry, predicate: "label == '240 x 180; local 0/240; equal true'"), "The native reader reevaluates with its new size")
        XCTAssertTrue(wait(observations, predicate: "label != '\(previous)'"), "The snapshot participates in onChange")
        let unchanged = observations.label
        app.buttons["Repaint geometry"].tap()
        XCTAssertTrue(wait(app.staticTexts["types.repaints"], predicate: "label == 'Repaints: 1'"), "Content must actually reevaluate at the same size")
        XCTAssertEqual(observations.label, unchanged, "Repainting at the same size does not emit another change")
        for (button, message) in [
            ("Reject geometry write", "Cannot assign through GeometryProxy"),
            ("Reject global frame", "Only local geometry frames are supported"),
            ("Reject missing record member", "Square has no member 'missing'"),
            ("Reject missing object member", "ModelObject has no member 'missing'"),
            ("Reject missing record binding", "Square has no stored property 'missing'"),
            ("Reject missing object binding", "ModelObject has no stored property 'missing'"),
        ] {
            app.buttons[button].tap()
            XCTAssertTrue(diagnostic(app, message).waitForExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts["types.commits"].label, "Commits: 0")
            XCTAssertEqual(geometry.label, "240 x 180; local 0/240; equal true")
        }
        keepScreenshot(app, "1136-protocols-geometry")
        app.terminate()
        for (scenario, name, message) in [
            ("malformed", "MalformedProtocol.swift", "Protocol accessors must be get or get set"),
            ("deep", "DeepProtocol.swift", "Code is nested too deeply"),
        ] {
            let invalid = launchSwift("display-swift-type-features-\(scenario)", flag: true)
            openSwiftDisplay(invalid, named: name)
            invalid.buttons["Run \(name)"].tap()
            XCTAssertTrue(invalid.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", message)).firstMatch.waitForExistence(timeout: 10))
            XCTAssertFalse(invalid.staticTexts["Must not run"].exists)
            invalid.terminate()
        }
    }

    @MainActor func testSwiftProtocolExtensionsCannotSilentlyDisappear() {
        continueAfterFailure = false
        let app = launchSwift("display-swift-type-features-extension", flag: true); defer { app.terminate() }
        openSwiftDisplay(app, named: "ProtocolExtension.swift")
        app.buttons["Run ProtocolExtension.swift"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Extensions require a previously declared concrete type'")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Must not run"].exists, "A discarded default implementation must refuse the program")
    }

    /// #1038: a real hosted source app exercises grouped dictionary values,
    /// enum keys, mapValues and tuple-key lookup in the interpreter.
    @MainActor func testDisplayedSwiftDictionaryAppGroupsAndTalliesItems() {
        continueAfterFailure = false
        let app = launchSwift("display-swift-dictionary", flag: true); defer { app.terminate() }
        openSwiftDisplay(app, named: "Dictionary.swift")
        let run = app.buttons["Run Dictionary.swift"]
        XCTAssertTrue(run.waitForExistence(timeout: 10)); run.tap()
        XCTAssertTrue(app.staticTexts["dictionary.tally"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["dictionary.tally"].label, "2 fruit / 1 drinks")
        XCTAssertEqual(app.staticTexts["dictionary.count"].label, "2 categories / 3 items")
        XCTAssertTrue(app.staticTexts["Apple"].exists)
        XCTAssertTrue(app.staticTexts["Tea"].exists)
        app.buttons["Dictionary checks"].tap()
        let state = app.staticTexts["dictionary.state"]
        let report = app.staticTexts["dictionary.report"]
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["dictionary.description"].label, #"["a": 1] / [:]"#,
                       "Descriptions preserve dictionary syntax, including the empty dictionary")
        app.buttons["Exercise dictionaries"].tap()
        let expectedState = "3/5/4; buckets 1; notes 1/nil; flags 1; calls 1/2"
        let expectedReport = "read 7/5/1; copy 10/9; loops 24/24; mapped 10/12/true/true; keys 5/1/true"
        XCTAssertTrue(wait(state, predicate: "label == '\(expectedState)'"),
                      "Integer/Bool keys, nil removal, nested nil and exactly-once default/key writeback")
        XCTAssertEqual(report.label, expectedReport, "Lazy read does not insert; copies and tuple transforms preserve values")
        app.buttons["Skip missing chained write"].tap()
        XCTAssertEqual(state.label, expectedState, "A skipped optional write does not insert a missing key")
        XCTAssertEqual(report.label, expectedReport)
        keepScreenshot(app, "1038-dictionary-values")
        for (button, message) in [
            ("Fail dictionary write", "out of range"),
            ("Reject mutable key", "Invalid dictionary key"),
            ("Exhaust dictionary copies", "ran too long"),
            ("Exceed dictionary limit", "dictionary grew past 100000 entries"),
        ] {
            app.buttons[button].tap()
            XCTAssertTrue(diagnostic(app, message).waitForExistence(timeout: 5), button)
            XCTAssertEqual(state.label, expectedState, "Every failed action restores nested dictionary state")
            XCTAssertEqual(report.label, expectedReport, "Rollback includes other writes in the same action")
        }
        keepScreenshot(app, "1038-dictionary-limit-rollback")
    }

    /// #1142: a nil optional-chain receiver skips the rest of its postfix chain
    /// (arguments, later indexes, lazy defaults, closure calls and assignment
    /// right-hand sides); a present receiver runs normally, and parentheses end
    /// the chain, so a nil group is an operand error rather than a skip.
    @MainActor func testDisplayedSwiftOptionalChainSkipsMissingLinks() {
        continueAfterFailure = false
        let app = launchSwift("display-swift-optional-chain", flag: true); defer { app.terminate() }
        openSwiftDisplay(app, named: "OptionalChain.swift")
        let run = app.buttons["Run OptionalChain.swift"]
        XCTAssertTrue(run.waitForExistence(timeout: 10)); run.tap()
        let state = app.staticTexts["optionalChain.state"]
        let report = app.staticTexts["optionalChain.report"]
        XCTAssertTrue(wait(state, predicate: "label == 'one 1/1; parent 0/child; missing -9; ghost -9; notes 1; calls 0/0'"),
                      "The fixture starts with its declared values before any chain runs")
        XCTAssertEqual(report.label, "ready")
        let expectedState = "one 3/2; parent 1/nil; missing -9; ghost -9; notes 1; calls 9/3"
        let expectedReport = "-1/no tag/-2/-4/11/1/1/1/1/no deep/blank/2/10/-10"
        app.buttons["Exercise optional chains"].tap()
        _ = wait(state, predicate: "label == '\(expectedState)'")
        XCTAssertEqual(state.label, expectedState, "Missing receivers skip argument, index, default, closure and RHS; present receivers run once")
        XCTAssertEqual(report.label, expectedReport, "Skipped chains yield nil fallbacks; ?? and parentheses bound the chain")
        app.buttons["Fail after optional write"].tap()
        XCTAssertTrue(diagnostic(app, "out of range").waitForExistence(timeout: 5))
        XCTAssertEqual(state.label, expectedState, "A later error rolls back optional writes made before it")
        XCTAssertEqual(report.label, expectedReport)
        app.buttons["Fail grouped optional chain"].tap()
        XCTAssertTrue(diagnostic(app, "Expected a number but found nil").waitForExistence(timeout: 5),
                      "A parenthesized nil chain is an operand, not a skip")
        XCTAssertEqual(state.label, expectedState, "The grouped operand error rolls back the earlier write")
        XCTAssertEqual(report.label, expectedReport)
        for button in ["Fail forced nil", "Fail forced nil field"] {
            app.buttons[button].tap()
            XCTAssertTrue(diagnostic(app, "Unexpected nil while force unwrapping").waitForExistence(timeout: 5))
            XCTAssertEqual(state.label, expectedState)
        }
        app.buttons["Exercise receiver order"].tap()
        XCTAssertTrue(wait(app.staticTexts["optionalChain.order"], predicate: "label == 'RARANN/4'"), "Computed receivers run once before arguments; nil skips arguments and writes")
        XCTAssertEqual(state.label, expectedState)
        keepScreenshot(app, "1142-optional-chain-rollback")
    }

    @MainActor func testDisplayedSwiftModelsInitializeAndRollback() {
        continueAfterFailure = false
        let app = launchSwift("display-swift-model-initializers", flag: true); defer { app.terminate() }
        openSwiftDisplay(app, named: "Models.swift")
        app.buttons["Run Models.swift"].tap()
        let state = app.staticTexts["models.state"]
        XCTAssertTrue(wait(state, predicate: "label == 'First/2/3'"))
        app.buttons["Construct models"].tap()
        XCTAssertTrue(wait(state, predicate: "label == 'Next/5/4'"))
        for (button, error) in [("Reject incomplete initializer", "did not initialize 'value'"),
                                ("Fail constructor mutation", "out of range"),
                                ("Reject extra initializer argument", "Unexpected argument")] {
            app.buttons[button].tap()
            XCTAssertTrue(diagnostic(app, error).waitForExistence(timeout: 5))
            XCTAssertEqual(state.label, "Next/5/4", "Failed construction restores value and reference mutations")
        }
        keepScreenshot(app, "1146-model-initializers")
        app.terminate()
        let bootstrap = launchSwift("display-swift-model-bootstrap", flag: true); defer { bootstrap.terminate() }
        openSwiftDisplay(bootstrap, named: "ModelBootstrap.swift")
        bootstrap.buttons["Run ModelBootstrap.swift"].tap()
        XCTAssertTrue(diagnostic(bootstrap, "did not initialize 'value'").waitForExistence(timeout: 5))
        XCTAssertFalse(bootstrap.staticTexts["Must not run"].exists, "State initialization errors cannot become silent nil state")
        bootstrap.terminate()
        for (scenario, file, error) in [("model-malformed-init", "MalformedInitializer.swift", "Expected ':'"),
                                        ("model-malformed-pattern", "MalformedPattern.swift", "Unexpected ')'")] {
            let invalid = launchSwift("display-swift-\(scenario)", flag: true)
            defer { invalid.terminate() }
            openSwiftDisplay(invalid, named: file)
            invalid.buttons["Run \(file)"].tap()
            XCTAssertTrue(diagnostic(invalid, error).waitForExistence(timeout: 5))
            XCTAssertFalse(invalid.staticTexts["Must not run"].exists)
            invalid.terminate()
        }
    }

    @MainActor func testDisplayedSwiftEnumPayloadsBindAndStayBounded() {
        continueAfterFailure = false
        let app = launchSwift("display-swift-model-payloads", flag: true); defer { app.terminate() }
        openSwiftDisplay(app, named: "Events.swift")
        app.buttons["Run Events.swift"].tap()
        let state = app.staticTexts["events.state"]
        let report = app.staticTexts["events.report"]
        XCTAssertTrue(wait(state, predicate: "label == 'count 2/2'"))
        app.buttons["Wrap payload"].tap()
        XCTAssertTrue(wait(state, predicate: "label == 'wrapped hello/-1'"))
        app.buttons["Compare payloads"].tap()
        let expected = "true/false/message(text: \"ok\")"
        XCTAssertTrue(wait(report, predicate: "label == %@", value: expected))
        for (button, error) in [("Exhaust payload nesting", "Enum payloads are nested too deeply"),
                                ("Reject payload arity", "Expected 1 payload argument"),
                                ("Reject payload label", "Expected payload label 'text'"),
                                ("Reject payload pattern", "Expected 1 payload pattern")] {
            app.buttons[button].tap()
            XCTAssertTrue(diagnostic(app, error).waitForExistence(timeout: 5))
            XCTAssertEqual(state.label, "wrapped hello/-1")
            XCTAssertEqual(report.label, expected, "Payload failures roll back the whole action")
        }
        keepScreenshot(app, "1146-enum-payloads")
    }

    /// #1036: a hosted stopwatch advances from its view-lifetime timer.
    @MainActor func testDisplayedSwiftTimerTicksAndStopsWithRunner() {
        continueAfterFailure = false
        let app = launchSwift("display-swift-timer", flag: true); defer { app.terminate() }
        openSwiftDisplay(app, named: "Stopwatch.swift")
        let run = app.buttons["Run Stopwatch.swift"]
        run.tap()
        let ticks = app.staticTexts["stopwatch.ticks"]
        XCTAssertTrue(ticks.waitForExistence(timeout: 10))
        let probe = app.staticTexts["swiftApp.timerProbe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        XCTAssertTrue(wait(probe, predicate: "label CONTAINS 'subscriptions: 8'"), "All eight initial subscribers are admitted")
        app.buttons["Add ninth subscriber"].tap()
        XCTAssertTrue(app.staticTexts["Ninth subscriber"].waitForExistence(timeout: 5))
        XCTAssertTrue(wait(probe, predicate: "label CONTAINS 'subscriptions: 8'"), "The ninth view subscription is refused at the per-runner cap")
        app.buttons["Fail one subscriber"].tap()
        XCTAssertTrue(wait(probe, predicate: "label CONTAINS 'subscriptions: 7'"), "The repeatedly failing subscriber stops after three transactional failures")
        let priorTicks = ticks.label
        XCTAssertTrue(wait(ticks, predicate: "label != '\(priorTicks)'"), "Independent subscribers keep ticking after their sibling stops")
        app.navigationBars.containing(.staticText, identifier: "Stopwatch").buttons["Done"].firstMatch.tap()
        XCTAssertTrue(wait(ticks, predicate: "exists == false"), "Dismissing the runner removes timer content")
        XCTAssertTrue(run.waitForExistence(timeout: 5), "Runner dismissal returns to the document")
        run.tap()
        XCTAssertTrue(ticks.waitForExistence(timeout: 5))
        XCTAssertTrue(wait(probe, predicate: "label CONTAINS 'global: 8'"), "The first runner's subscriptions were cancelled rather than retained")
        app.navigationBars.containing(.staticText, identifier: "Stopwatch").buttons["Done"].firstMatch.tap()
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
        // #909: a root TabView gets the shared chrome per tab, and the tab's own
        // toolbar stays beside Done (a stack around the TabView would hide it).
        assertToolbarTint(app, title: "Expenses", excluding: ["Plan trip", "Leave app"])
        let expensesBar = app.navigationBars.containing(.staticText, identifier: "Expenses").firstMatch
        XCTAssertTrue(expensesBar.buttons["Plan trip"].exists, "The tab keeps its toolbar under the shared chrome")
        app.buttons["Add food"].tap()
        XCTAssertTrue(app.staticTexts["New food"].waitForExistence(timeout: 5), "A store method appends a @Published expense")
        XCTAssertTrue(app.staticTexts["$12.25"].exists)
        keepScreenshot(app, "889-6-budget-expenses")

        app.buttons["Summary"].tap()
        let total = app.staticTexts["budget.total"]
        XCTAssertTrue(total.waitForExistence(timeout: 5), "The TabView switches to the second tab")
        assertToolbarTint(app, title: "Summary")
        // Optional.map: applied to a value, and nil stays nil for `??`.
        XCTAssertTrue(app.staticTexts["Latest: New food"].exists, "Optional.map applies its closure to a value")
        XCTAssertTrue(app.staticTexts["No big expense"].exists, "Optional.map on nil is nil")
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
        let unsupported = broken.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Line 5: Custom initializers'")).firstMatch
        XCTAssertTrue(unsupported.waitForExistence(timeout: 10), "Unsupported syntax names its line instead of running")
        keepScreenshot(broken, "889-8-unsupported-syntax")
        XCTAssertFalse(broken.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Dictionaries are not supported'")).firstMatch.exists,
                       "Supported dictionary literals do not create obsolete warnings")
        XCTAssertFalse(broken.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Enum cases with associated values are not supported'")).firstMatch.exists,
                       "Supported payload cases do not create obsolete warnings")
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
        // #909: a program with no NavigationStack or title still gets the
        // shared chrome, titled with the file name.
        assertToolbarTint(app, title: "Limits")
        XCTAssertTrue(diagnostic(app, "Unknown name 'Map'").exists, "An unsupported view renders an inline diagnostic beside working views")

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
            XCTAssertEqual(app.staticTexts["limits.state"].label, "State: 1/1/1/0",
                           "A failed action restores nested bindings, arrays and aliased object fields")
            XCTAssertEqual(taps.label, "Taps: \(expectedTaps)", "Failed writes to other state slots roll back too")
            XCTAssertFalse(app.staticTexts["must roll back"].exists, "Other @State writes are restored")
            XCTAssertTrue(diagnostic(app, "Action cancelled; state restored.").exists)
            assertSwiftDiagnosticStyle(app, diagnostic(app, message))
            app.buttons["Count"].tap()
            expectedTaps += 1
            XCTAssertTrue(wait(taps, predicate: "label == %@", value: "Taps: \(expectedTaps)"), "The app stays responsive after \(button)")
            XCTAssertTrue(wait(diagnostic(app, message), predicate: "exists == false"), "A successful action clears the diagnostic")
        }

        app.buttons["Commit changes"].tap()
        XCTAssertTrue(wait(app.staticTexts["limits.state"], predicate: "label == %@", value: "State: 2/5/2/1"),
                      "A successful action commits all writes and recomputes derived state")

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

    @MainActor func testSwiftDiagnosticsPreserveSiblingViews() {
        continueAfterFailure = false
        let app = launchSwift("display-swift-diagnostics", flag: true); defer { app.terminate() }
        openSwiftDisplay(app, named: "Diagnostics.swift")
        app.buttons["Run Diagnostics.swift"].tap()
        let taps = app.staticTexts["diagnostics.taps"]
        XCTAssertTrue(taps.waitForExistence(timeout: 10), "A bad footer must not replace the whole body")
        for title in ["Nested sibling", "After nested failure", "Last sibling"] {
            XCTAssertTrue(app.staticTexts[title].exists, "Working sibling survives: \(title)")
        }
        XCTAssertTrue(diagnostic(app, "Line 7: 'count' is a property, not a method").exists)
        XCTAssertTrue(diagnostic(app, "Line 10: Index 4 is out of range").exists)
        XCTAssertTrue(app.staticTexts["Row -10"].exists)
        XCTAssertTrue(app.staticTexts["Row 10"].exists, "A failing ForEach row does not erase later rows")
        XCTAssertTrue(diagnostic(app, "Division by zero").exists)
        assertToolbarTint(app, title: "Diagnostics")
        keepScreenshot(app, "1039-contained-siblings")
        app.buttons["Count"].tap()
        XCTAssertTrue(wait(taps, predicate: "label == %@", value: "Taps: 1"))
        app.buttons["Fail action"].tap()
        XCTAssertTrue(diagnostic(app, "Action cancelled; state restored.").waitForExistence(timeout: 10))
        XCTAssertEqual(taps.label, "Taps: 1", "Value helpers still throw into the action transaction")
        keepScreenshot(app, "1039-action-still-throws")
        app.buttons["Count"].tap()
        XCTAssertTrue(wait(taps, predicate: "label == %@", value: "Taps: 2"))
        XCTAssertTrue(wait(diagnostic(app, "Action cancelled; state restored."), predicate: "exists == false"))
    }

    @MainActor func testSwiftUnsupportedDiagnosticsAreBoundedAndMalformedSyntaxStops() {
        continueAfterFailure = false
        let app = launchSwift("display-swift-diagnostic-cap", flag: true); defer { app.terminate() }
        openSwiftDisplay(app, named: "Capped.swift")
        app.buttons["Run Capped.swift"].tap()
        let capped = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Stopped after 10 unsupported constructs'")).firstMatch
        XCTAssertTrue(capped.waitForExistence(timeout: 10))
        XCTAssertTrue(capped.label.contains("Line 2: Custom initializers"))
        XCTAssertTrue(capped.label.contains("Line 11: Custom initializers"))
        XCTAssertFalse(capped.label.contains("Line 12:"))
        XCTAssertFalse(app.staticTexts["Must not run"].exists, "A partial parse is never executed")
        keepScreenshot(app, "1039-bounded-diagnostics")
        app.terminate()

        let malformed = launchSwift("display-swift-diagnostic-malformed", flag: true); defer { malformed.terminate() }
        openSwiftDisplay(malformed, named: "Malformed.swift")
        malformed.buttons["Run Malformed.swift"].tap()
        XCTAssertTrue(malformed.staticTexts.matching(NSPredicate(format: "label CONTAINS \"Unbalanced '{'\"")).firstMatch.waitForExistence(timeout: 10),
                      "Malformed delimiters are fatal, not speculative recovery points")
        XCTAssertTrue(malformed.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Line 2: Custom initializers'")).firstMatch.exists,
                      "A fatal syntax error retains independent unsupported diagnostics already collected")
        malformed.terminate()

        let malformedGeneric = launchSwift("display-swift-diagnostic-generic-malformed", flag: true); defer { malformedGeneric.terminate() }
        openSwiftDisplay(malformedGeneric, named: "MalformedGeneric.swift")
        malformedGeneric.buttons["Run MalformedGeneric.swift"].tap()
        XCTAssertTrue(malformedGeneric.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Malformed generic parameter clause'")).firstMatch.waitForExistence(timeout: 10),
                      "Malformed generic parameter syntax is fatal rather than swallowed")
        XCTAssertFalse(malformedGeneric.staticTexts["Must not run"].exists, "Malformed generic syntax never executes a partial app")
    }

    /// The shared info card uses neutral primary copy and a separate semantic
    /// error icon. Catch a regression to the old all-red, ad-hoc Label using
    /// rendered ink rather than asserting production source text.
    @MainActor private func assertSwiftDiagnosticStyle(_ app: XCUIApplication, _ message: XCUIElement) {
        XCTAssertTrue(message.isHittable, "The full error is readable over the runner")
        let frame = message.frame
        XCTAssertTrue(app.windows.firstMatch.frame.contains(frame), "Error copy stays inside the sheet")
        guard let image = app.screenshot().image.cgImage else { return XCTFail("Missing screenshot") }
        let scale = CGFloat(image.width) / app.windows.firstMatch.frame.width
        guard let crop = image.cropping(to: frame.applying(CGAffineTransform(scaleX: scale, y: scale))) else {
            return XCTFail("Missing diagnostic crop")
        }
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        guard let context = CGContext(data: &pixels, width: crop.width, height: crop.height, bitsPerComponent: 8,
                                      bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return XCTFail("Missing diagnostic pixels")
        }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        var neutralInk = 0
        var coloredInk = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let channels = [Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2])]
            guard channels.max()! > 150 else { continue }
            if channels.max()! - channels.min()! < 35 { neutralInk += 1 }
            else { coloredInk += 1 }
        }
        XCTAssertGreaterThan(neutralInk, 100, "Shared TronInfoCard copy uses readable primary ink")
        XCTAssertLessThan(Double(coloredInk) / Double(max(1, neutralInk + coloredInk)), 0.15,
                          "Diagnostic text must use shared primary ink, not an all-red custom label")
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
