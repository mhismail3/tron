import XCTest

final class HitTargetContainerUITests: XCTestCase {
    @MainActor
    func testDashboardChatAndNewSessionVisibleEdgesAreTappable() throws {
        let app = XCUIApplication()
        app.launch()

        let briefingBand = app.buttons["agent-briefing-dashboard-band"]
        XCTAssertTrue(
            briefingBand.waitForExistence(timeout: 20),
            "Agent Briefing dashboard band should be visible"
        )
        tapVisibleEdge(briefingBand, dx: 0.96)
        XCTAssertTrue(
            app.staticTexts["Agent Briefing"].waitForExistence(timeout: 20),
            "Tapping the far visible edge of the briefing band should open Agent Briefing"
        )
        keepScreenshot(named: "hit-target-agent-briefing-edge-tap")
        tapVisibleEdge(app.buttons["Close"].firstMatch, dx: 0.85)

        let settingsButton = app.buttons["Settings"].firstMatch
        assertNearlySquare(settingsButton, named: "dashboard settings")
        tapVisibleEdge(settingsButton, dx: 0.88)
        XCTAssertTrue(
            app.staticTexts["Settings"].waitForExistence(timeout: 20),
            "Tapping the visible edge of the settings toolbar button should open Settings"
        )
        keepScreenshot(named: "hit-target-settings-edge-tap")
        tapVisibleEdge(app.buttons["Close"].firstMatch, dx: 0.85)

        let recentSession = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "last active")
        ).firstMatch
        XCTAssertTrue(recentSession.waitForExistence(timeout: 20), "A recent session row should be visible")
        tapVisibleEdge(recentSession, dx: 0.94)

        let chatSettingsButton = app.buttons["Settings"].firstMatch
        assertNearlySquare(chatSettingsButton, named: "chat settings")
        tapVisibleEdge(chatSettingsButton, dx: 0.88)
        XCTAssertTrue(
            app.staticTexts["Settings"].waitForExistence(timeout: 20),
            "Tapping the chat settings button edge should open Settings"
        )
        keepScreenshot(named: "hit-target-chat-settings-edge-tap")
        tapVisibleEdge(app.buttons["Close"].firstMatch, dx: 0.85)

        let backButton = app.buttons["Back"].firstMatch
        assertNearlySquare(backButton, named: "chat back")
        tapVisibleEdge(backButton, dx: 0.14)
        XCTAssertTrue(
            briefingBand.waitForExistence(timeout: 20),
            "Tapping the visible edge of the chat back button should return to the dashboard"
        )

        let newSessionButton = app.buttons["New Session"].firstMatch
        tapVisibleEdge(newSessionButton, dx: 0.88)
        XCTAssertTrue(
            app.staticTexts["New Session"].waitForExistence(timeout: 20),
            "Tapping the visible edge of the new-session button should open the sheet"
        )
        keepScreenshot(named: "hit-target-new-session-edge-tap")
        tapVisibleEdge(app.buttons["Close"].firstMatch, dx: 0.14)
    }

    @MainActor
    private func tapVisibleEdge(
        _ element: XCUIElement,
        dx: CGFloat,
        dy: CGFloat = 0.5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: 20), "Element should exist before edge tap", file: file, line: line)
        element.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy)).tap()
    }

    @MainActor
    private func assertNearlySquare(
        _ element: XCUIElement,
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: 20), "\(name) should exist", file: file, line: line)
        let frame = element.frame
        XCTAssertLessThanOrEqual(
            abs(frame.width - frame.height),
            1,
            "\(name) should expose a square hit frame, got \(frame)",
            file: file,
            line: line
        )
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
