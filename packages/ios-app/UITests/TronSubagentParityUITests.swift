import XCTest

/// Hosted journeys exercise the real chat/composer, pill details, Activity and
/// read-only child transport. Fixtures are bounded projections, not live workers.
final class TronSubagentParityUITests: XCTestCase {
    /// The production History sheet must move one exact row between lifecycle
    /// sections without retaining a stale live cell from another lazy collection.
    @MainActor
    func testHistoryGroupingVisualCaptures() throws {
        continueAfterFailure = false
        for scheme in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-subagent-parity-fixture", "-history-grouping", "-\(scheme)"]
            app.launch()
            defer { app.terminate() }
            let open = app.buttons["Subagent History"]
            XCTAssertTrue(open.waitForExistence(timeout: 10), app.debugDescription)
            open.tap()
            let worker = app.buttons["subagent-row-worker"]
            XCTAssertTrue(worker.waitForExistence(timeout: 5), app.debugDescription)
            // Expand the real medium-first sheet to show both lifecycle sections.
            app.swipeUp()
            XCTAssertTrue(app.staticTexts["Recently finished"].waitForExistence(timeout: 5))
            XCTAssertTrue((worker.value as? String)?.contains("Live") == true)
            XCTAssertLessThan(app.staticTexts["Active"].frame.maxY, worker.frame.minY)
            XCTAssertLessThan(worker.frame.maxY, app.staticTexts["Recently finished"].frame.minY)
            let completed = app.buttons["subagent-row-completed"]
            XCTAssertLessThan(app.staticTexts["Recently finished"].frame.maxY, completed.frame.minY)
            try capture("1306-history-mixed-\(scheme)")
            app.buttons["Finish worker"].tap()
            let settled = NSPredicate(format: "value CONTAINS %@", "Completed")
            expectation(for: settled, evaluatedWith: worker)
            waitForExpectations(timeout: 5)
            XCTAssertFalse(app.staticTexts["Active"].exists, app.debugDescription)
            XCTAssertEqual(app.buttons.matching(identifier: "subagent-row-worker").count, 1)
            XCTAssertFalse((worker.value as? String)?.contains("LIVE OUTPUT") == true)
            XCTAssertLessThan(app.staticTexts["Recently finished"].frame.maxY, worker.frame.minY)
            try capture("1306-history-finished-\(scheme)")
        }
    }

    @MainActor
    func testHistoryQueuedPausedResumedAndTerminalExecutions() throws {
        continueAfterFailure = false
        // Each terminal outcome ends a distinct execution. Resume gets its own
        // exact process ID while its settled paused predecessor stays history.
        for outcome in ["completed", "failed", "stopped"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-subagent-parity-fixture", "-history-grouping", "-history-lifecycle", "-history-\(outcome)", "-dark"]
            app.launch()
            defer { app.terminate() }
            XCTAssertTrue(app.buttons["Subagent History"].waitForExistence(timeout: 10))
            app.buttons["Subagent History"].tap()
            XCTAssertTrue(app.buttons["subagent-row-worker"].waitForExistence(timeout: 5))
            app.swipeUp()
            let stages = [("worker", "Queued", true), ("worker", "Live", true),
                          ("worker", "Pausing…", true), ("worker", "Paused", false),
                          ("resumed", "Queued", true), ("resumed", "Live", true),
                          ("resumed", outcome.capitalized, false)]
            for (index, stage) in stages.enumerated() {
                if index > 0 { app.buttons["Advance lifecycle"].tap() }
                assertHistoryRow(app, id: stage.0, status: stage.1, active: stage.2)
                assertHistoryRow(app, id: "completed", status: "Completed", active: false)
                if index >= 4 {
                    assertHistoryRow(app, id: "worker", status: "Paused", active: false)
                    XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "subagent-row-")).count, 3)
                }
                if !stage.2 { XCTAssertFalse(app.staticTexts["Active"].exists) }
                if index == 3 || index == 4 || index == 6 {
                    try capture("1306-history-\(outcome)-stage-\(index)")
                }
            }
        }
    }

    @MainActor
    private func assertHistoryRow(_ app: XCUIApplication, id: String, status: String, active: Bool,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let row = app.buttons["subagent-row-\(id)"]
        // Match the lifecycle prefix, not a word in the title/output metadata.
        expectation(for: NSPredicate(format: "value BEGINSWITH %@", "\(status),"), evaluatedWith: row)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.buttons.matching(identifier: "subagent-row-\(id)").count, 1, file: file, line: line)
        let recent = app.staticTexts["Recently finished"]
        XCTAssertTrue(recent.exists, file: file, line: line)
        if active {
            XCTAssertTrue(app.staticTexts["Active"].exists, file: file, line: line)
            XCTAssertLessThan(app.staticTexts["Active"].frame.maxY, row.frame.minY, file: file, line: line)
            XCTAssertLessThan(row.frame.maxY, recent.frame.minY, file: file, line: line)
        } else {
            XCTAssertLessThan(recent.frame.maxY, row.frame.minY, file: file, line: line)
            XCTAssertFalse((row.value as? String)?.contains("LIVE OUTPUT") == true, file: file, line: line)
        }
    }

    @MainActor
    func testHomeChipLabelCaptures() throws {
        for scheme in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-subagent-parity-fixture", "-home-chip-labels", "-\(scheme)"]
            app.launch()
            defer { app.terminate() }
            XCTAssertTrue(app.staticTexts["The requested changes are ready for review."].waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["Task, Completed, 42ms"].exists, app.debugDescription)
            XCTAssertTrue(app.buttons["Notify, Completed, 18ms"].exists, app.debugDescription)
            XCTAssertTrue(app.buttons["Worker · Simplify Home chip labels, Reported"].exists, app.debugDescription)
            XCTAssertFalse(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Tron Home ·")).firstMatch.exists)
            XCTAssertFalse(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Tron Notify ·")).firstMatch.exists)
            try capture("home-chip-labels-\(scheme)")
        }
    }

    @MainActor
    func testHomeResultReadableMessageAndNestedInfo() throws {
        continueAfterFailure = false
        for mode in ["legacy", "typed-report", "plain-report", "malformed-report"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-subagent-parity-fixture", "-presentation-polish", "-\(mode)", mode == "typed-report" ? "-dark" : "-light"]
            app.launch()
            defer { app.terminate() }
            let pill = app.buttons[mode == "typed-report" ? "Worker, Reported" : "Worker, Received"]
            XCTAssertTrue(pill.waitForExistence(timeout: 10), app.debugDescription)
            pill.tap()
            try capture("852-\(mode)-message")
            if mode == "plain-report" {
                XCTAssertTrue(app.staticTexts["Plain report remains complete."].exists)
            } else if mode == "malformed-report" {
                XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "preserve this text")).firstMatch.exists)
            } else {
                XCTAssertTrue(app.staticTexts["Actual report"].waitForExistence(timeout: 3), app.debugDescription)
                XCTAssertTrue(app.staticTexts["All requested changes are preserved."].exists)
                XCTAssertTrue(app.staticTexts[mode == "typed-report" ? "Needs input" : "Final report"].exists)
                XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "receiptId")).firstMatch.exists)
            }
            app.buttons["Technical details"].tap()
            XCTAssertTrue(app.staticTexts["ORIGIN"].waitForExistence(timeout: 5), app.debugDescription)
            try capture("852-\(mode)-info")
            if mode == "legacy" {
                let envelope = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Inspect report envelope")).firstMatch
                for _ in 0..<6 {
                    if envelope.exists && envelope.isHittable { break }
                    app.swipeUp()
                }
                XCTAssertTrue(envelope.isHittable, app.debugDescription)
                XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "evidence/native-result.xcresult")).firstMatch.exists, app.debugDescription)
                try capture("852-evidence-table")
                envelope.tap()
                XCTAssertTrue(app.staticTexts["Report envelope"].waitForExistence(timeout: 5), app.debugDescription)
                try capture("852-envelope-inspector")
                try XCTUnwrap(app.buttons.matching(identifier: "Done").allElementsBoundByIndex.last(where: \.isHittable)).tap()
            }
            try XCTUnwrap(app.buttons.matching(identifier: "Done").allElementsBoundByIndex.last(where: \.isHittable)).tap()
            XCTAssertTrue(app.buttons["Technical details"].waitForExistence(timeout: 5))
            try XCTUnwrap(app.buttons.matching(identifier: "Done").allElementsBoundByIndex.last(where: \.isHittable)).tap()
            XCTAssertTrue(pill.waitForExistence(timeout: 5))
        }
    }

    @MainActor
    func testNotificationBodyFillsSheetWidth() throws {
        continueAfterFailure = false
        for scheme in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-subagent-parity-fixture", "-presentation-polish", "-\(scheme)"]
            if scheme == "dark" { app.launchArguments.append("-accessibility-type") }
            app.launch()
            defer { app.terminate() }
            let errors = app.buttons.matching(NSPredicate(format: "label == %@", "Tron · Notification, Error"))
            XCTAssertTrue(errors.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
            for index in 0..<2 {
                errors.element(boundBy: 1 - index).tap()
                let text = index == 0 ? "HTTP 429" : "Long error context"
                XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.waitForExistence(timeout: 5), app.debugDescription)
                try capture("852-error-\(scheme)-\(index)")
                let card = app.descendants(matching: .any).matching(identifier: "chat-notification-body").firstMatch
                XCTAssertTrue(card.exists)
                let viewport = app.scrollViews.element(boundBy: app.scrollViews.count - 1)
                XCTAssertGreaterThanOrEqual(card.frame.width, viewport.frame.width - 40, "Short and long cards use the same standard content width")
                app.buttons["Done"].tap()
            }
        }
    }

    @MainActor
    func testAdjacentNotificationsKeepCompactIndependentTargets() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-subagent-parity-fixture", "-presentation-polish", "-light"]
        app.launch()
        defer { app.terminate() }
        let errors = app.buttons.matching(NSPredicate(format: "label == %@", "Tron · Notification, Error"))
        XCTAssertTrue(errors.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(errors.count, 2)
        let frames = [errors.element(boundBy: 0).frame, errors.element(boundBy: 1).frame].sorted { $0.minY < $1.minY }
        try capture("852-notification-run")
        XCTAssertGreaterThanOrEqual(frames[1].midY - frames[0].midY, 44, "Independent targets must not overlap")
        XCTAssertLessThanOrEqual(frames[1].midY - frames[0].midY, 46, "A contiguous run must not repeat turn spacing")
        // The AX label can hug the glass; prove the actual 44-point target with
        // a native tap outside its visible face but within its own clearance.
        let first = errors.element(boundBy: 1)
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: 0, dy: 20)).tap()
        XCTAssertTrue(app.staticTexts["HTTP 429"].waitForExistence(timeout: 5), "Expanded target must open its own event, not its neighbour")
    }

    @MainActor
    func testInterleavedNotificationsPreserveConversationAndToolBoundaries() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-subagent-parity-fixture", "-presentation-polish", "-interleaved-events", "-dark"]
        app.launch()
        defer { app.terminate() }
        let errors = app.buttons.matching(NSPredicate(format: "label == %@", "Tron · Notification, Error"))
        XCTAssertTrue(errors.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(errors.count, 2)
        XCTAssertTrue(app.staticTexts["Conversation between independent events."].exists, app.debugDescription)
        XCTAssertTrue(app.buttons["Read file, Interrupted"].exists, app.debugDescription)
        let frames = [errors.element(boundBy: 0).frame, errors.element(boundBy: 1).frame].sorted { $0.minY < $1.minY }
        XCTAssertGreaterThan(frames[1].midY - frames[0].midY, 80, "Prose and tools must remain chronological boundaries, not join an event run")
        try capture("852-interleaved-events")
    }

    @MainActor
    func testNativeOrganizationAndPills() throws {
        continueAfterFailure = false
        for scheme in ["light", "dark"] {
            let app = launch(scheme: scheme)
            defer { app.terminate() }
            let org = app.buttons["Subagents"]
            XCTAssertTrue(org.waitForExistence(timeout: 10), app.debugDescription)
            try capture("org-\(scheme)")
            try verifyPills(app, scheme: scheme)
            org.tap()
            XCTAssertTrue(app.staticTexts["Running subagents"].waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(app.staticTexts["Worker"].exists, app.debugDescription)
            XCTAssertFalse(app.staticTexts["PRIVATE PROVIDER STATUS"].exists)
            XCTAssertFalse(app.staticTexts["PRIVATE PROVIDER FRAME"].exists)
            XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "PI_SUBAGENT_ASYNC_JSON")).firstMatch.exists)
            XCTAssertTrue(app.staticTexts["PARITY_CHILD_COMPLETE"].exists, app.debugDescription)
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "parity.txt")).firstMatch.exists, app.debugDescription)
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "2 tools")).firstMatch.exists, app.debugDescription)
            try capture("sheet-\(scheme)")
            app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Worker")).firstMatch.tap()
            XCTAssertTrue(app.staticTexts["Child transcript reached through the native row."].waitForExistence(timeout: 10), app.debugDescription)
            try capture("child-transcript-\(scheme)")
        }
    }

    @MainActor
    func testSettingsResourcesAndDefinitionDiagnostic() throws {
        continueAfterFailure = false
        for scheme in ["light", "dark"] {
            let app = launch(scheme: scheme, resources: true)
            defer { app.terminate() }
            XCTAssertTrue(app.staticTexts["Project Resources"].waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(app.staticTexts["Pi Subagents"].exists, app.debugDescription)
            XCTAssertTrue(app.staticTexts["Council"].exists, app.debugDescription)
            XCTAssertTrue(app.buttons["project-resource-subagents-0"].exists, app.debugDescription)
            app.swipeUp()
            XCTAssertTrue(app.staticTexts["Diagnostics"].waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "fallbackModels")).firstMatch.exists, app.debugDescription)
            try capture("settings-resources-\(scheme)")
        }
    }

    @MainActor
    func testHistoricalSessionPills() throws {
        continueAfterFailure = false
        let app = launch(scheme: "dark", historical: true)
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Subagent, Progress Update"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["Extension content"].exists, "Historic classification belongs to Gateway, not npm parsing")
        try verifyPills(app, scheme: "historical-dark")
        try capture("historical-dark")
    }

    @MainActor
    func testPendingWakePreflightJourney() throws {
        try verifyRuntimeWake(stage: "pending-wake")
    }

    @MainActor
    func testQueuedWakeSteerJourney() throws {
        try verifyRuntimeWake(stage: "queued-wake")
    }

    @MainActor
    private func verifyRuntimeWake(stage: String) throws {
        continueAfterFailure = false
        for scheme in ["light", "dark"] {
            let app = launch(scheme: scheme, inputStage: stage)
            defer { app.terminate() }
            XCTAssertTrue(app.buttons["Subagent, Needs Attention"].waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertFalse(app.staticTexts["Subagent updates above."].exists,
                "An internal input must have no user-position bubble before canonical binding: \(stage)")
            XCTAssertFalse(app.buttons["Subagent, Update"].exists, "A hidden wake must not gain a pill")
            try capture("\(stage)-\(scheme)")
        }
    }

    @MainActor
    func testQueuedMaintainerRemainsVisible() throws {
        continueAfterFailure = false
        for scheme in ["light", "dark"] {
            let app = launch(scheme: scheme, inputStage: "queued-wake", queuedMaintainer: true)
            defer { app.terminate() }
            XCTAssertTrue(app.staticTexts["Maintainer queued message"].waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertFalse(app.staticTexts["Subagent updates above."].exists)
            try capture("queued-maintainer-\(scheme)")
        }
    }

    @MainActor
    private func verifyPills(_ app: XCUIApplication, scheme: String) throws {
        XCTAssertFalse(app.buttons["Subagent, Update"].exists, "Internal wake must not add a pill")
        for (label, body, name) in [
            ("Subagent, Progress Update", "Worker has finished discovery.", "progress"),
            ("Subagent, Child Update", "Reviewer child result: no blockers.", "child-note"),
            ("Subagent, Needs Attention", "May the worker proceed?", "decision")
        ] {
            let pill = app.buttons[label]
            XCTAssertTrue(pill.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertEqual(app.buttons.matching(identifier: label).count, 1, "One pill per subagent message")
            XCTAssertFalse(app.staticTexts["Subagent updates above."].exists, "Wake must not be a user bubble")
            try capture("\(name)-pill-\(scheme)")
            pill.tap()
            XCTAssertTrue(app.staticTexts[body].waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertFalse(app.staticTexts["Unknown source"].exists)
            XCTAssertFalse(app.staticTexts["Context received"].exists)
            try capture("\(name)-details-\(scheme)")
            app.buttons["Done"].tap()
        }
    }

    @MainActor
    private func launch(scheme: String, historical: Bool = false, inputStage: String? = nil, queuedMaintainer: Bool = false, resources: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-subagent-parity-fixture", "-\(scheme)"] + (historical ? ["-historical"] : [])
        if let inputStage { app.launchArguments.append("-\(inputStage)") }
        if resources { app.launchArguments.append("-resources") }
        if queuedMaintainer { app.launchArguments.append("-queued-maintainer") }
        app.launch()
        return app
    }

    @MainActor
    private func capture(_ name: String) throws {
        let image = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = "611-\(name)"; attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["TRON_SUBAGENT_CAPTURE_DIR"] {
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try image.pngRepresentation.write(to: root.appendingPathComponent("\(name).png"), options: .atomic)
        }
    }
}
