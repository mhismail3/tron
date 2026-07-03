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
    func testChatHistoryScrollKeepsMessageViewportPopulated() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--tron-ui-test-onboarding-complete")
        app.launch()
        try openRecentChatIfNeeded(in: app)

        let messageScrollView = app.scrollViews["chat-message-scroll-view"].firstMatch
        XCTAssertTrue(
            messageScrollView.waitForExistence(timeout: 20),
            "Chat should expose a stable message scroll view for history validation"
        )

        XCTAssertGreaterThan(
            visibleMessageElementCount(in: app),
            0,
            "Chat should render at least one visible message before history scrolling"
        )

        for attempt in 1...4 {
            messageScrollView.swipeDown()
            RunLoop.current.run(until: Date().addingTimeInterval(0.9))

            XCTAssertGreaterThan(
                visibleMessageElementCount(in: app),
                0,
                "History swipe \(attempt) must not leave the message viewport blank"
            )
        }

        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        app.activate()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))

        XCTAssertGreaterThan(
            visibleMessageElementCount(in: app),
            0,
            "Foreground resume from an open chat must restore visible message history"
        )
        XCTAssertTrue(app.textViews["Message input"].exists || app.textFields["Message input"].exists)
        keepScreenshot(named: "chat-history-scroll-populated")
    }

    @MainActor
    func testRecentChatOpensAtLatestTurnRepeatedly() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--tron-ui-test-onboarding-complete")
        app.launch()

        for attempt in 1...3 {
            try openRecentChatIfNeeded(in: app)

            let latestMessage = app.descendants(matching: .any)
                .matching(identifier: "chat-message-latest")
                .firstMatch
            XCTAssertTrue(
                latestMessage.waitForExistence(timeout: 20),
                "Open attempt \(attempt) should render the latest message after initial bottom anchoring"
            )
            XCTAssertTrue(
                latestMessage.isHittable,
                "Open attempt \(attempt) should land at the bottom with the latest message in the viewport"
            )
            XCTAssertFalse(app.staticTexts["Loading latest messages"].exists)
            keepScreenshot(named: "chat-latest-open-\(attempt)")

            let backButton = app.buttons.matching(
                NSPredicate(format: "label == %@ OR label CONTAINS[c] %@", "Back", "back")
            ).firstMatch
            XCTAssertTrue(backButton.waitForExistence(timeout: 10), "Back button should return to dashboard")
            backButton.tap()
            XCTAssertTrue(
                app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "last active"))
                    .firstMatch
                    .waitForExistence(timeout: 15),
                "Dashboard session rows should be visible before the next open attempt"
            )
        }
    }

    @MainActor
    func testBottomRubberBandDoesNotDisplaceLatestTurn() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--tron-ui-test-onboarding-complete")
        app.launch()
        try openRecentChatIfNeeded(in: app)

        let messageScrollView = app.scrollViews["chat-message-scroll-view"].firstMatch
        XCTAssertTrue(
            messageScrollView.waitForExistence(timeout: 20),
            "Chat should expose a stable message scroll view for bottom rubber-band validation"
        )

        let latestMessage = app.descendants(matching: .any)
            .matching(identifier: "chat-message-latest")
            .firstMatch
        XCTAssertTrue(latestMessage.waitForExistence(timeout: 20))
        XCTAssertTrue(latestMessage.isHittable)

        for attempt in 1...3 {
            messageScrollView.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.7))

            XCTAssertTrue(
                latestMessage.isHittable,
                "Bottom rubber-band attempt \(attempt) should keep the latest message in the viewport"
            )
            XCTAssertGreaterThan(
                visibleMessageElementCount(in: app),
                0,
                "Bottom rubber-band attempt \(attempt) must not leave the message viewport blank"
            )
        }

        keepScreenshot(named: "chat-bottom-rubber-band-stable")
    }

    @MainActor
    private func openRecentChatIfNeeded(in app: XCUIApplication) throws {
        if app.scrollViews["chat-message-scroll-view"].waitForExistence(timeout: 5) {
            return
        }

        let recentSession = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "last active")
        ).firstMatch

        guard recentSession.waitForExistence(timeout: 20) else {
            throw XCTSkip("No session rows are available for chat history scroll validation")
        }
        recentSession.tap()
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

    @MainActor
    private func visibleMessageElementCount(in app: XCUIApplication) -> Int {
        app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "label BEGINSWITH %@ OR label == %@",
                    "You:",
                    "Assistant message"
                )
            )
            .allElementsBoundByIndex
            .filter(\.isHittable)
            .count
    }
}
