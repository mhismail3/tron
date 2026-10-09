import XCTest

/// Hosted journeys exercise the real chat/composer, pill details, Activity and
/// read-only child transport. Fixtures are bounded projections, not live workers.
final class TronSubagentParityUITests: XCTestCase {
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
            XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "PI_SUBAGENT_ASYNC_JSON")).firstMatch.exists)
            try capture("sheet-\(scheme)")
            app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Worker")).firstMatch.tap()
            XCTAssertTrue(app.staticTexts["Child transcript reached through the native row."].waitForExistence(timeout: 10), app.debugDescription)
            try capture("child-transcript-\(scheme)")
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
    private func launch(scheme: String, historical: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-subagent-parity-fixture", "-\(scheme)"] + (historical ? ["-historical"] : [])
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
