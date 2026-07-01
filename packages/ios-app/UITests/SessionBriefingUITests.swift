import XCTest

final class SessionBriefingUITests: XCTestCase {
    @MainActor
    func testAgentBriefingAndSessionBriefingValidationPath() throws {
        let app = XCUIApplication()
        app.launch()

        let briefingBand = app.buttons["agent-briefing-dashboard-band"]
        XCTAssertTrue(briefingBand.waitForExistence(timeout: 20), "Agent Briefing dashboard band should be visible above grouped sessions")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertFalse(
            app.staticTexts["Connect to the server to read scoped activity."].exists,
            "Connected dashboard should not keep stale disconnected briefing copy"
        )
        keepScreenshot(named: "dashboard-agent-briefing-band")
        briefingBand.tap()

        XCTAssertTrue(app.staticTexts["Agent Briefing"].waitForExistence(timeout: 20), "Agent Briefing sheet should open")
        XCTAssertTrue(app.staticTexts["What Tron has been doing"].waitForExistence(timeout: 15), "Briefing should show activity section")
        XCTAssertTrue(app.staticTexts["Active work"].waitForExistence(timeout: 15), "Briefing should show active work section")
        keepScreenshot(named: "agent-briefing-sheet")

        app.staticTexts["Active work"].tap()
        let evidenceDetail = app.otherElements["agent-briefing-evidence-detail"]
        if !evidenceDetail.waitForExistence(timeout: 8) {
            let firstInfoButton = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Runtime", "activity")
            ).firstMatch
            if firstInfoButton.waitForExistence(timeout: 5) {
                firstInfoButton.tap()
            }
        }
        keepScreenshot(named: "agent-briefing-drilldown")

        app.buttons["Close"].tap()

        if !app.buttons["Context status"].waitForExistence(timeout: 8) {
            let recentSession = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "last active")
            ).firstMatch
            XCTAssertTrue(recentSession.waitForExistence(timeout: 20), "A recent session row should be visible")
            recentSession.tap()
        }

        let contextPill = app.buttons["Context status"]
        XCTAssertTrue(contextPill.waitForExistence(timeout: 20), "Context status pill should be tappable")
        contextPill.tap()

        XCTAssertTrue(app.staticTexts["Session Briefing"].waitForExistence(timeout: 20), "Session Briefing sheet should open")
        XCTAssertTrue(app.staticTexts["Briefing"].waitForExistence(timeout: 10), "Narrative session briefing section should be visible")
        XCTAssertTrue(app.staticTexts["Context and Model Controls"].waitForExistence(timeout: 10), "Context/model controls should be visible")
        XCTAssertTrue(app.staticTexts["Context Breakdown"].waitForExistence(timeout: 10), "Context Breakdown section should be visible")
        XCTAssertTrue(app.staticTexts["context used"].waitForExistence(timeout: 10), "Context summary should render")

        let invalidPayloadError = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "did not return a Session Briefing payload")
        ).firstMatch
        XCTAssertFalse(invalidPayloadError.exists, "Session Briefing should not show an invalid server payload error")

        keepScreenshot(named: "session-briefing-sheet")

        let modelCard = app.buttons["session-briefing-model-card"]
        XCTAssertTrue(modelCard.waitForExistence(timeout: 15), "Model picker card should be available")
        modelCard.tap()

        XCTAssertTrue(app.staticTexts["Models"].waitForExistence(timeout: 20), "Model picker should open from Session Briefing")
        keepScreenshot(named: "session-briefing-model-picker")
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
