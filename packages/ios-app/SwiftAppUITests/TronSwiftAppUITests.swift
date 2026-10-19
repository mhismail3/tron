import XCTest
import UIKit

/// Displayed `.swift` files that run as interpreted apps (#889, #1006) through the
/// readonly attachment fixture in the `TronSwiftAppUITests` target.
final class TronSwiftAppUITests: XCTestCase {
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

    /// #1319: the recovered remote-build design remains an honest offline app,
    /// delivered through the same chat artifact and managed runner as user files.
    @MainActor func testRecoveredBuildsPreviewFiltersSearchesAndReopens() {
        continueAfterFailure = false
        let app = launchSwift("display-swift-builds-preview", flag: true); defer { app.terminate() }
        openSwiftDisplay(app, named: "BuildsPreview.swift")
        let run = app.buttons["Run BuildsPreview.swift"]
        XCTAssertTrue(run.waitForExistence(timeout: 10)); run.tap()
        let historical = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Historical snapshot'")).firstMatch
        XCTAssertTrue(historical.waitForExistence(timeout: 10), app.debugDescription)
        let optimized = app.staticTexts["Preview 3 #1163 + #1155"]
        let debug = app.staticTexts["#1112 continuous prose selection"]
        XCTAssertTrue(optimized.exists)
        keepScreenshot(app, "1319-builds-snapshot")

        app.segmentedControls.buttons["Fast debug"].tap()
        XCTAssertTrue(debug.waitForExistence(timeout: 5))
        XCTAssertFalse(optimized.exists)
        app.segmentedControls.buttons["Optimized"].tap()
        XCTAssertTrue(optimized.waitForExistence(timeout: 5))
        XCTAssertFalse(debug.exists)
        app.segmentedControls.buttons["All"].tap()
        debug.tap()
        XCTAssertTrue(app.staticTexts["What to test"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["f95544a20"].exists)
        let install = app.buttons["Install"]
        XCTAssertTrue(install.exists)
        XCTAssertFalse(install.isEnabled, "The preview must never install an old build")
        keepScreenshot(app, "1319-build-detail-disabled-install")
        let back = app.navigationBars.buttons["Tron builds"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription); back.tap()
        XCTAssertTrue(historical.waitForExistence(timeout: 5))

        let search = app.searchFields.firstMatch
        if !search.isHittable { app.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
        search.tap(); search.typeText("1112")
        XCTAssertTrue(debug.waitForExistence(timeout: 5))
        XCTAssertFalse(optimized.exists, "Search filters the original title/branch data")
        keepScreenshot(app, "1319-builds-search")
        search.typeText("-no-match")
        XCTAssertTrue(app.staticTexts["No builds"].waitForExistence(timeout: 5))
        keepScreenshot(app, "1319-builds-empty")
        // Native iOS search temporarily replaces the navigation bar. Close it
        // through its observed control before using the runner's Done action.
        app.buttons["close"].tap()
        app.segmentedControls.buttons["Fast debug"].tap()
        XCTAssertFalse(optimized.exists)
        XCTAssertEqual(app.staticTexts["swiftApp.linkProbe"].label, "Links opened: none")
        app.navigationBars.containing(.staticText, identifier: "Tron builds").buttons["Done"].firstMatch.tap()
        XCTAssertTrue(run.waitForExistence(timeout: 5))
        run.tap()
        XCTAssertTrue(optimized.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["No builds"].exists, "A fresh runner has no stale empty-search result")
        XCTAssertTrue(app.segmentedControls.buttons["All"].isSelected)
        app.navigationBars.containing(.staticText, identifier: "Tron builds").buttons["Done"].firstMatch.tap()
        XCTAssertTrue(run.waitForExistence(timeout: 5))
        closeDocument(app)
        openSwiftDisplay(app, named: "BuildsPreview.swift")
        XCTAssertTrue(run.waitForExistence(timeout: 5), "The chat artifact reopens after both sheets close")
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
                                ("Reject extra initializer argument", "Unexpected argument"),
                                ("Reject partial self", "did not initialize 'value'"),
                                ("Reject initializer return", "Initializers cannot return a value"),
                                ("Reject unknown stored field", "has no stored property 'unknown'")] {
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
                                        ("model-malformed-pattern", "MalformedPattern.swift", "Unexpected ')'"),
                                        ("model-malformed-comma", "MalformedComma.swift", "Expected ')'"),
                                        ("model-malformed-raw", "MalformedRaw.swift", "Raw-value enums cannot have payloads")] {
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
        XCTAssertTrue(wait(state, predicate: "label == 'count 2/2'"), "Runner labels: \(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        XCTAssertTrue(wait(app.staticTexts["events.kind"], predicate: "label == 'count'"), "A case-only pattern ignores associated values")
        XCTAssertTrue(app.segmentedControls.buttons["Inline"].waitForExistence(timeout: 5),
                      "A SwiftUI symbol shared with an owned enum case still styles native views")
        XCTAssertTrue(wait(app.staticTexts["events.draft"], predicate: "label == '1/none'"), "An omitted optional var starts as nil")
        app.buttons["Construct stored case"].tap()
        XCTAssertTrue(wait(state, predicate: "label == 'count 3/3'"))
        XCTAssertTrue(wait(app.staticTexts["events.kind"], predicate: "label == 'target'"), "A qualified value pattern compares by value")
        app.buttons["Wrap payload"].tap()
        XCTAssertTrue(wait(state, predicate: "label == 'wrapped hello/-1'"))
        XCTAssertTrue(wait(app.staticTexts["events.kind"], predicate: "label == 'other'"))
        app.buttons["Compare payloads"].tap()
        let expected = "true/false/message(text: \"ok\")/2/1/2"
        XCTAssertTrue(wait(report, predicate: "label == %@", value: expected))
        for (button, error) in [("Exhaust payload nesting", "Enum payloads are nested too deeply"),
                                ("Exhaust payload containers", "Enum payloads are nested too deeply"),
                                ("Reject payload arity", "Expected 1 payload argument"),
                                ("Reject payload label", "Expected payload label 'text'"),
                                ("Reject payload pattern", "Expected 1 payload pattern"),
                                ("Reject empty payload pattern", "Expected 1 payload pattern"),
                                ("Reject payload ordering", "Payload enum ordering is not supported")] {
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

        // #1160: Link and openURL reach the host's real openURL only for an
        // install manifest or a page on the paired Gateway's host. The fixture
        // records what its OpenURLAction receives in the runner's link probe.
        app.buttons["Summary"].tap()
        app.buttons["Statements"].tap()
        let reset = app.buttons["Reset statement"], resets = app.staticTexts["budget.resets"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5)); reset.tap()
        XCTAssertTrue(app.buttons["Reset now"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.alerts.count, 0)
        let cancelReset = app.buttons["confirmation-cancel"]
        XCTAssertTrue(cancelReset.label.contains("Keep statement"), "Authored cancellation labels survive the shared sheet")
        cancelReset.tap()
        XCTAssertEqual(resets.label, "Resets 0")
        reset.tap(); app.buttons["Reset now"].tap()
        XCTAssertTrue(wait(resets, predicate: "label == %@", value: "Resets 1"))
        XCTAssertTrue(reset.exists, "Only the interpreted confirmation closes, not the displayed app")

        let attempts = app.staticTexts["budget.linkAttempts"]
        XCTAssertTrue(attempts.waitForExistence(timeout: 5))
        let opened = app.staticTexts["swiftApp.linkProbe"]
        XCTAssertTrue(opened.exists)
        XCTAssertEqual(opened.label, "Links opened: none")
        XCTAssertTrue(diagnostic(app, "Link to example.com is not allowed").exists,
                      "A Link to another host diagnoses in place instead of rendering")
        XCTAssertFalse(app.buttons["Foreign install"].exists)

        app.buttons["Open elsewhere"].tap()
        XCTAssertTrue(diagnostic(app, "Action cancelled; state restored").waitForExistence(timeout: 5))
        XCTAssertTrue(diagnostic(app, "Link to example.com is not allowed").exists)
        XCTAssertEqual(attempts.label, "Attempts 0", "A refused openURL rolls its action back")
        XCTAssertEqual(opened.label, "Links opened: none")

        let report = "https://original.example.test:8443/budget/report"
        app.buttons["Open report"].tap()
        let confirm = app.staticTexts["Open link?"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "A page on the Gateway's host asks first")
        XCTAssertEqual(app.alerts.count, 0)
        XCTAssertTrue(app.staticTexts[report].exists, "The confirmation shows the full URL")
        keepScreenshot(app, "1160-open-link-confirmation")
        app.buttons["confirmation-cancel"].tap()
        XCTAssertTrue(wait(confirm, predicate: "exists == false"))
        XCTAssertEqual(attempts.label, "Attempts 1")
        XCTAssertEqual(opened.label, "Links opened: none", "Cancel opens nothing")
        app.buttons["Open report"].tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); app.buttons["Open"].tap()
        XCTAssertTrue(wait(opened, predicate: "label == %@", value: "Links opened: \(report)"), "Open hands the URL to the host's openURL")

        let install = "itms-services://?action=download-manifest&url=https://original.example.test:8443/builds/budget/manifest.plist"
        app.buttons["Install budget build"].tap()
        XCTAssertTrue(wait(opened, predicate: "label == %@", value: "Links opened: \(report) \(install)"),
                      "An install manifest on the Gateway's host opens directly; iOS asks before installing")
        XCTAssertFalse(confirm.exists)
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

    @MainActor private func launch(_ scenario: String, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-readonly-attachment-fixture", "-readonly-preview-scenario", scenario, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extraArguments
        app.launch(); return app
    }
    @MainActor private func wait(_ element: XCUIElement, predicate: String, value: String? = nil) -> Bool {
        let condition = value.map { NSPredicate(format: predicate, $0) } ?? NSPredicate(format: predicate)
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: condition, object: element)], timeout: 10) == .completed
    }
    @MainActor private func keepScreenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
