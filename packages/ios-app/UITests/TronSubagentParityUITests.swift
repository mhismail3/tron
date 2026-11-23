import XCTest

final class TronSubagentParityUITests: XCTestCase {
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
            app.swipeUp()
            XCTAssertTrue((worker.value as? String)?.contains("Running") == true)
            let completed = app.buttons["subagent-row-completed"]
            XCTAssertLessThan(worker.frame.maxY, completed.frame.minY)
            try capture("1306-history-mixed-\(scheme)")
            app.buttons["Finish worker"].tap()
            let settled = NSPredicate(format: "value CONTAINS %@", "Completed")
            expectation(for: settled, evaluatedWith: worker)
            waitForExpectations(timeout: 5)
            XCTAssertEqual(app.buttons.matching(identifier: "subagent-row-worker").count, 1)
            XCTAssertFalse((worker.value as? String)?.contains("LIVE OUTPUT") == true)
            try capture("1306-history-finished-\(scheme)")
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
        let first = inVisualOrder(errors)[0]
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: 0, dy: 20)).tap()
        XCTAssertTrue(app.staticTexts["HTTP 429"].waitForExistence(timeout: 5), "Expanded target must open its own event, not its neighbour")
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
            let worker = app.buttons.matching(NSPredicate(format: "label == %@", "Worker")).firstMatch
            XCTAssertTrue(worker.exists, app.debugDescription)
            let workerValue = worker.value as? String ?? ""
            XCTAssertFalse(app.staticTexts["PRIVATE PROVIDER STATUS"].exists)
            XCTAssertFalse(app.staticTexts["PRIVATE PROVIDER FRAME"].exists)
            XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "PI_SUBAGENT_ASYNC_JSON")).firstMatch.exists)
            XCTAssertTrue(workerValue.contains("PARITY_CHILD_COMPLETE"), workerValue)
            XCTAssertTrue(workerValue.contains("parity.txt"), workerValue)
            XCTAssertTrue(workerValue.contains("2 tools"), workerValue)
            try capture("sheet-\(scheme)")
            app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Worker")).firstMatch.tap()
            XCTAssertTrue(app.staticTexts["Child transcript reached through the native row."].waitForExistence(timeout: 10), app.debugDescription)
            try capture("child-transcript-\(scheme)")
        }
    }

    @MainActor
    func testStopSubagentAsksForConfirmation() throws {
        continueAfterFailure = false
        for scheme in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-subagent-parity-fixture", "-\(scheme)", "-stoppable"]
            app.launch()
            defer { app.terminate() }
            let org = app.buttons["Subagents"]
            XCTAssertTrue(org.waitForExistence(timeout: 10), app.debugDescription)
            org.tap()
            app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Worker")).firstMatch.tap()
            let stop = app.buttons["stop-subagent-button"]
            XCTAssertTrue(stop.waitForExistence(timeout: 10), app.debugDescription)
            stop.tap()
            XCTAssertTrue(app.staticTexts["Stop Worker?"].waitForExistence(timeout: 5), app.debugDescription)
            Thread.sleep(forTimeInterval: 0.8)
            try capture("stop-subagent-confirmation-\(scheme)")
            let cancel = app.buttons["confirmation-cancel"]
            cancel.tap()
            XCTAssertTrue(cancel.waitForNonExistence(timeout: 5), "Cancel dismisses the confirmation without stopping")
        }
    }

    @MainActor
    func testActivityRowsCaptures() throws {
        continueAfterFailure = false
        for scheme in ["light", "dark"] {
            for state in ["running", "recent"] {
                let app = XCUIApplication()
                app.launchArguments = ["-tron-subagent-parity-fixture", "-\(scheme)", "-subagentRecentFinishedRetentionMinutes.v1", "5"]
                    + (state == "recent" ? ["-activity-preview-recent"] : [])
                app.launch()
                defer { app.terminate() }
                let org = app.buttons["Subagents"]
                XCTAssertTrue(org.waitForExistence(timeout: 10), app.debugDescription)
                if state == "running" { try capture("2090-composer-\(scheme)") }
                org.tap()
                XCTAssertTrue(app.staticTexts[state == "running" ? "Running subagents" : "Completed subagents"].waitForExistence(timeout: 5), app.debugDescription)
                let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "subagent-row-"))
                XCTAssertEqual(rows.count, 1, app.debugDescription)
                XCTAssertTrue((rows.firstMatch.value as? String)?.hasPrefix(state == "running" ? "Live," : "Completed,") == true,
                              "\(rows.firstMatch.value ?? "")")
                if state == "running" {
                    XCTAssertTrue((rows.firstMatch.value as? String)?.contains("Claude Fable 5.2 · Medium thinking") == true,
                                  "\(rows.firstMatch.value ?? "")")
                }
                XCTAssertFalse(app.staticTexts["DETAILS"].exists, "The bespoke DETAILS heading is retired")
                XCTAssertFalse(app.staticTexts["LIVE OUTPUT"].exists, "The bespoke LIVE OUTPUT heading is retired")
                try capture("2090-activity-\(state)-medium-\(scheme)")
                app.swipeUp()
                try capture("2090-activity-\(state)-large-\(scheme)")
            }
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
    private func launch(scheme: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-subagent-parity-fixture", "-\(scheme)"]
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
