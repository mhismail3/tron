import XCTest

@MainActor
final class TronAgentBehaviorRegressionUITests: XCTestCase {
    func testNumericMapsShowValuesWithoutRoutineEditors() {
        continueAfterFailure = true
        for home in [false, true] {
            for (mode, dark, large) in [("light", false, false), ("dark", true, false), ("light-xxxl", false, true), ("dark-xxxl", true, true)] {
                let app = XCUIApplication()
                app.launchArguments = home
                    ? ["-tron-home-dashboard-fixture", "-home-shell-ready", "-settings-scope-review"] + (dark ? ["-home-dark"] : [])
                    : ["-tron-settings-renderer-fixture", "-settings-nested", "-settings-expanded-review", "-agent-behavior-regression"] + (dark ? ["-settings-renderer-dark"] : [])
                app.launchArguments += large ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : []
                app.launch()
                if home {
                    XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 15))
                    app.buttons["home-pinned-row"].tap()
                    let ring = app.buttons["session-context-button"]
                    XCTAssertTrue(ring.waitForExistence(timeout: 15))
                    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: ring)], timeout: 10), .completed)
                    ring.tap()
                    expand(app, "Manage Home")
                    tap(app, "home-manage-settings")
                    expand(app, "Home Settings")
                } else {
                    XCTAssertTrue(app.buttons["Open Settings"].waitForExistence(timeout: 15))
                    app.buttons["Open Settings"].tap()
                    expand(app, "Global Settings")
                    tap(app, "settings-link-Agent Behavior")
                    expand(app, "Agent Behavior")
                }
                let row = app.descendants(matching: .any)["settings-row-permissions.budget.task"]
                let viewport = app.windows.firstMatch.frame.insetBy(dx: 0, dy: 140)
                for _ in 0..<12 where !(row.exists && viewport.contains(row.frame)) { app.swipeUp(velocity: .slow) }
                XCTAssertTrue(row.exists, app.debugDescription)
                if row.exists {
                    XCTAssertTrue(viewport.contains(row.frame), "Capture the whole numeric-map row: \(row.frame)")
                    capture(app, "numeric-map-\(home ? "home" : "global")-\(mode)")
                    XCTAssertTrue(row.staticTexts["input 200000"].exists, row.debugDescription)
                    XCTAssertFalse(row.buttons["Task budget"].exists, "Use the existing agent settings/shared card, not a numeric-map form")
                    XCTAssertFalse(row.buttons["settings-row-permissions.budget.task-reset"].exists, "A read-only map must not advertise a native reset")
                    if home { XCTAssertTrue(row.staticTexts["Overridden"].exists, "Read-only values retain their owned-override provenance") }
                }
                app.terminate()
            }
        }
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
        let window = app.windows.firstMatch.frame
        var previous: CGRect?
        for _ in 0..<12 {
            let frame = button.exists ? button.frame : nil
            let settled = frame.map { $0 == previous && window.contains($0) && $0.minY > 140 } ?? false
            if let frame, button.isHittable,
               settled || (frame.minY > 140 && frame.maxY < window.height - 70) {
                button.tap(); return
            }
            previous = frame
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
