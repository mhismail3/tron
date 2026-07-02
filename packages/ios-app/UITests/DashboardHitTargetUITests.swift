import XCTest

final class DashboardHitTargetUITests: XCTestCase {
    @MainActor
    func testAgentBriefingBandVisibleEdgeOpensSheet() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--tron-ui-test-onboarding-complete")
        app.launch()

        let briefingBand = app.buttons["agent-briefing-dashboard-band"].firstMatch
        XCTAssertTrue(
            briefingBand.waitForExistence(timeout: 20),
            "Agent Briefing dashboard band should be visible above grouped sessions"
        )

        briefingBand.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()

        XCTAssertTrue(
            app.staticTexts["Agent Briefing"].waitForExistence(timeout: 10),
            "Tapping near the visible trailing edge of the Agent Briefing band should open its sheet"
        )
    }

    @MainActor
    func testEngineCockpitProgressiveDisclosurePath() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--tron-ui-test-onboarding-complete")
        app.launch()

        let cockpitBand = app.buttons["engine-cockpit-dashboard-band"].firstMatch
        XCTAssertTrue(
            cockpitBand.waitForExistence(timeout: 20),
            "Engine Cockpit dashboard band should be visible above grouped sessions"
        )
        keepScreenshot(named: "engine-cockpit-dashboard-band")

        cockpitBand.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()

        XCTAssertTrue(app.staticTexts["Engine Cockpit"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Capabilities"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Activity"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Core"].exists)
        XCTAssertFalse(app.buttons["Discovery"].exists)
        XCTAssertTrue(app.staticTexts["Capability catalog verified"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Built-in engine operations"].waitForExistence(timeout: 10))
        keepScreenshot(named: "engine-cockpit-capabilities")

        let coreEngineGroup = app.buttons["capability-group-core_engine"].firstMatch
        XCTAssertTrue(coreEngineGroup.waitForExistence(timeout: 10))
        coreEngineGroup.tap()
        XCTAssertTrue(app.staticTexts["Core Engine"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts["Can Tron inspect and invoke its own primitive engine?"].waitForExistence(timeout: 10)
        )
        XCTAssertTrue(app.staticTexts["auth::clear"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["IdempotentWrite"].exists)
        keepScreenshot(named: "engine-cockpit-capability-detail")

        let operation = app.buttons["operation-row-auth::clear"].firstMatch
        XCTAssertTrue(operation.waitForExistence(timeout: 10))
        operation.tap()
        XCTAssertTrue(app.staticTexts["Operation Detail"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["How Tron Sees It"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Schema"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Provider-visible contract from the live capability catalog."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Request"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Response"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", #""additionalProperties" : false"#))
                .firstMatch
                .waitForExistence(timeout: 10),
            "Operation detail should show the pretty-printed request schema body"
        )
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", #""providers""#))
                .firstMatch
                .waitForExistence(timeout: 10),
            "Operation detail should show the pretty-printed response schema body"
        )
        XCTAssertTrue(app.staticTexts["Idempotent Write"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Tags"].waitForExistence(timeout: 10))
        keepScreenshot(named: "engine-cockpit-operation-detail")

        app.buttons["Close"].tap()
        app.buttons["Close"].tap()
        app.buttons["Activity"].tap()
        XCTAssertTrue(app.staticTexts["No engine work"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts["No engine or module work is running, waiting, or blocked."].waitForExistence(timeout: 10)
        )
        keepScreenshot(named: "engine-cockpit-activity-empty")
    }

    @MainActor
    private func keepScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let directory = ProcessInfo.processInfo.environment["TRON_UI_SCREENSHOT_DIR"]
            ?? "/tmp/tron-ui-validation-screenshots"
        let url = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("\(name).png")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }
}
