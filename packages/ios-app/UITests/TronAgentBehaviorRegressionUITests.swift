import XCTest

/// Production Settings -> Agent Behavior -> native lifecycle sheet over the hosted socket.
@MainActor
final class TronAgentBehaviorRegressionUITests: XCTestCase {
    func testTrustedProjectsLoadsAtMedium() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-nested", "-settings-expanded-review", "-agent-behavior-regression"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Open Settings"].waitForExistence(timeout: 15))
        app.buttons["Open Settings"].tap()
        expand(app, "Global Settings")
        tap(app, "settings-link-Agent Behavior")
        expand(app, "Agent Behavior")
        tap(app, "Trusted Projects")
        let add = app.buttons["Add Project"]
        XCTAssertTrue(add.waitForExistence(timeout: 15), app.debugDescription)
        let title = app.navigationBars.staticTexts["Trusted Projects"].firstMatch
        XCTAssertTrue(title.exists, app.debugDescription)
        XCTAssertGreaterThan(title.frame.minY, app.windows.firstMatch.frame.height * 0.35,
                             "The loaded sheet must open at medium, not full height")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "2072-trusted-projects-medium"
        attachment.lifetime = .keepAlways
        self.add(attachment)
    }

    func testTrustedProjectsErrorCanRetryWithoutStalling() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-nested", "-settings-expanded-review", "-agent-behavior-regression", "-projects-fail-once"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Open Settings"].waitForExistence(timeout: 15))
        app.buttons["Open Settings"].tap()
        expand(app, "Global Settings")
        tap(app, "settings-link-Agent Behavior")
        expand(app, "Agent Behavior")
        tap(app, "Trusted Projects")
        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["Retry"].tap()
        XCTAssertTrue(app.buttons["Add Project"].waitForExistence(timeout: 15), app.debugDescription)
    }

    func testRetiredCompactionRowsAreNotDisplayed() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-nested", "-settings-expanded-review", "-agent-behavior-regression"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Open Settings"].waitForExistence(timeout: 15))
        app.buttons["Open Settings"].tap()
        expand(app, "Global Settings")
        tap(app, "settings-link-Agent Behavior")
        expand(app, "Agent Behavior")
        XCTAssertTrue(app.staticTexts["Worker models"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["settings-row-context.compaction.enabled"].exists,
                       "Retired Automatic compaction must not be a read-only row, even with a saved value")
        XCTAssertFalse(app.descendants(matching: .any)["settings-row-model.thinking_role_summarizer_"].exists,
                       "Retired Summary thinking must not be a read-only row, even with a saved value")
    }

    func testMissingProjectResponseShowsRetryAndCanLoad() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-nested", "-settings-expanded-review", "-agent-behavior-regression", "-projects-withhold-once"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Open Settings"].waitForExistence(timeout: 15))
        app.buttons["Open Settings"].tap()
        expand(app, "Global Settings")
        tap(app, "settings-link-Agent Behavior")
        expand(app, "Agent Behavior")
        tap(app, "Trusted Projects")
        // Exercise the real client's existing 30-second request deadline, not a test-only timer.
        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 45), app.debugDescription)
        capture(app, "projects-missing-response-error")
        app.buttons["Retry"].tap()
        XCTAssertTrue(app.buttons["Add Project"].waitForExistence(timeout: 15), app.debugDescription)
    }

    func testGlobalValuePillFollowsReset() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-nested", "-settings-expanded-review", "-agent-behavior-regression"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Open Settings"].waitForExistence(timeout: 15))
        app.buttons["Open Settings"].tap()
        expand(app, "Global Settings")
        tap(app, "settings-link-Agent Behavior")
        expand(app, "Agent Behavior")
        let reset = app.buttons["settings-row-model.ref_role_chat_-reset"]
        XCTAssertTrue(reset.waitForExistence(timeout: 10), app.debugDescription)
        let row = app.descendants(matching: .any)["settings-row-model.ref_role_chat_"]
        let value = row.buttons.matching(NSPredicate(format: "NOT identifier ENDSWITH '-reset'")).firstMatch
        XCTAssertTrue(value.exists, row.debugDescription)
        XCTAssertLessThanOrEqual(reset.frame.maxX, value.frame.minX, "Reset must precede the rightmost value pill")
        XCTAssertGreaterThanOrEqual(reset.frame.width, 43.5)
        XCTAssertGreaterThanOrEqual(value.frame.height, 43.5)
    }

    func testAgentBehaviorReviewLightDark() {
        continueAfterFailure = false
        for mode in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-nested", "-settings-expanded-review", "-agent-behavior-regression"]
                + (mode == "dark" ? ["-settings-renderer-dark"] : [])
            app.launch()
            XCTAssertTrue(app.buttons["Open Settings"].waitForExistence(timeout: 15))
            app.buttons["Open Settings"].tap()
            expand(app, "Global Settings")
            tap(app, "settings-link-Agent Behavior")
            expand(app, "Agent Behavior")
            capture(app, "agent-top-\(mode)")
            app.swipeUp()
            capture(app, "agent-middle-\(mode)")
            app.swipeUp()
            capture(app, "agent-bottom-\(mode)")
            tap(app, "Trusted Projects")
            XCTAssertTrue(app.buttons["Example"].waitForExistence(timeout: 15), app.debugDescription)
            let title = app.navigationBars.staticTexts["Trusted Projects"].firstMatch
            XCTAssertGreaterThan(title.frame.minY, app.windows.firstMatch.frame.height * 0.35)
            capture(app, "trusted-medium-\(mode)")
            app.terminate()
        }
    }

    func testSessionValuePillFollowsRevertLightDark() {
        continueAfterFailure = false
        for mode in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-session-configuration-fixture", "-settings-scope-review", "-fixture-appearance", mode]
            app.launch()
            XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 10))
            app.buttons["Stop session"].tap()
            tap(app, "chat-settings-link")
            expand(app, "Session Settings")
            tap(app, "settings-section-tools-open")
            expand(app, "Tools")
            let row = app.descendants(matching: .any)["settings-row-tools.active"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
            let revert = row.buttons.matching(NSPredicate(format: "identifier ENDSWITH '-reset'")).firstMatch
            let value = row.buttons.matching(NSPredicate(format: "label == 'Tools' AND NOT identifier ENDSWITH '-reset'")).firstMatch
            XCTAssertTrue(revert.exists && value.exists, row.debugDescription)
            XCTAssertLessThanOrEqual(revert.frame.maxX, value.frame.minX)
            XCTAssertGreaterThanOrEqual(revert.frame.width, 43.5)
            XCTAssertGreaterThanOrEqual(value.frame.height, 43.5)
            capture(app, "session-revert-\(mode)")
            app.terminate()
        }
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "2072-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tap(_ app: XCUIApplication, _ id: String) {
        let button = app.buttons[id].firstMatch
        for _ in 0..<12 {
            if button.exists && button.isHittable,
               button.frame.minY > 140, button.frame.maxY < app.windows.firstMatch.frame.height - 70 {
                button.tap(); return
            }
            let upward = !(button.exists && button.frame.minY < 140)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.7 : 0.45))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.45 : 0.7)))
        }
        XCTFail("Missing button \(id): \(app.debugDescription)")
    }

    private func expand(_ app: XCUIApplication, _ name: String) {
        let title = app.navigationBars.staticTexts[name].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), app.debugDescription)
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)))
    }
}
