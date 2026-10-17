import XCTest

/// Sheets of every family tint their toolbar icons like their titles (#963):
/// Settings and its indigo, cyan and emerald groups, the Automations and
/// Knowledge sheets, and Manage Home with a sub-sheet that takes its row's tint.
/// The paired-device sheet, reachable only with a real Gateway, is covered by
/// `RealGatewayPairAndChatUITests.testSettingsClarityPillsTextDoneAndAccountsFirst`.
/// The nested-menu journeys retain the native Settings/History presentations
/// that #877 reported as inert; both now open on iOS 26.5 without a UI rewrite.
final class TronSheetTintUITests: XCTestCase {
    @MainActor
    func testSettingsSheetToolbarsTakeTheirTitleTint() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-navigation-fixture"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["settings-link-Connections"].waitForExistence(timeout: 10), app.debugDescription)
        assertToolbarTint(app, title: "Settings")
        for title in ["Connections", "MCP Servers", "Appearance"] {
            let link = app.buttons["settings-link-\(title)"]
            for _ in 0..<12 where !link.isHittable { app.swipeUp() }
            link.tap()
            assertToolbarTint(app, title: title)
            app.buttons.matching(NSPredicate(format: "label == 'Done'")).allElementsBoundByIndex.last(where: \.isHittable)?.tap()
            XCTAssertTrue(app.navigationBars.staticTexts["Settings"].firstMatch.waitForExistence(timeout: 5))
            for _ in 0..<12 where !app.buttons["settings-link-Connections"].isHittable { app.swipeDown() }
        }
    }

    @MainActor
    func testNestedSessionsRetentionOpensAndPersistsInLightAndDark() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-mac-settings-fixture", "-settings-nested"]
            if appearance == "dark" { app.launchArguments.append("-settings-renderer-dark") }
            app.launch(); defer { app.terminate() }
            XCTAssertTrue(app.buttons["Open Settings"].waitForExistence(timeout: 10))
            app.buttons["Open Settings"].tap()
            let sessions = app.buttons["settings-link-Sessions"]
            for _ in 0..<12 where !sessions.isHittable { app.swipeUp() }
            XCTAssertTrue(sessions.isHittable, app.debugDescription)
            sessions.tap()
            let retention = app.buttons["Show finished subagents"]
            XCTAssertTrue(retention.waitForExistence(timeout: 5), app.debugDescription)
            let previous = retention.value as? String
            XCTAssertNotNil(previous)
            assertToolbarTint(app, title: "Sessions")
            retention.tap()
            let choice = app.buttons[previous == "Only active" ? "1 minute" : "Only active"]
            XCTAssertTrue(choice.waitForExistence(timeout: 5), "The control must open at sheet depth two: \(app.debugDescription)")
            let selected = choice.label
            let capture = XCTAttachment(screenshot: app.screenshot())
            capture.name = "877-retention-\(appearance)"; capture.lifetime = .keepAlways; add(capture)
            choice.tap()
            XCTAssertTrue(retention.waitForExistence(timeout: 5))
            XCTAssertEqual(retention.value as? String, selected)
            let done = app.buttons.matching(NSPredicate(format: "label == 'Done'")).allElementsBoundByIndex.filter(\.isHittable)
            XCTAssertEqual(done.count, 1)
            done.first?.tap()
            XCTAssertTrue(sessions.waitForExistence(timeout: 5)); sessions.tap()
            XCTAssertTrue(retention.waitForExistence(timeout: 5))
            XCTAssertEqual(retention.value as? String, selected, "The value survives reopening Sessions")
            retention.tap()
            let restore = app.buttons[previous ?? "Only active"]
            XCTAssertTrue(restore.waitForExistence(timeout: 5)); restore.tap()
            XCTAssertEqual(retention.value as? String, previous)
            app.terminate()
        }
    }

    @MainActor
    func testNestedHistoryMenuOpensEveryDestinationInLightAndDark() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-session-configuration-fixture", "-fixture-appearance", appearance]
            app.launch(); defer { app.terminate() }
            XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 10))
            app.buttons["Stop session"].tap()
            let history = app.buttons["Session History"]
            for _ in 0..<12 where !history.isHittable { app.swipeUp() }
            XCTAssertTrue(history.isHittable, app.debugDescription); history.tap()
            let actions = app.buttons["Actions for Nested history prompt"]
            XCTAssertTrue(actions.waitForExistence(timeout: 10), app.debugDescription)
            assertToolbarTint(app, title: "Session History")
            for (action, destination) in [("Edit From This Prompt", "Edit From This Prompt"),
                                           ("Fork New Session", "Fork Session"), ("Add Bookmark", "Bookmark")] {
                actions.tap()
                let menuAction = app.buttons[action]
                XCTAssertTrue(menuAction.waitForExistence(timeout: 5), app.debugDescription)
                if action == "Edit From This Prompt" {
                    let capture = XCTAttachment(screenshot: app.screenshot())
                    capture.name = "877-history-\(appearance)"; capture.lifetime = .keepAlways; add(capture)
                }
                menuAction.tap()
                if action == "Add Bookmark" {
                    let cancel = app.buttons["confirmation-cancel"]
                    XCTAssertTrue(cancel.waitForExistence(timeout: 5))
                    XCTAssertEqual(app.alerts.count, 0)
                    XCTAssertTrue(app.textFields["Label"].exists)
                    cancel.tap()
                    actions.tap(); app.buttons["Add Bookmark"].tap()
                    let field = app.textFields["Label"]
                    XCTAssertTrue(field.waitForExistence(timeout: 5))
                    field.tap(); field.typeText("Saved bookmark")
                    app.buttons["Save"].tap()
                    XCTAssertTrue(app.staticTexts["Saved bookmark"].waitForExistence(timeout: 5), app.debugDescription)
                    actions.tap(); app.buttons["Edit Bookmark"].tap()
                    XCTAssertTrue(app.buttons["Remove"].waitForExistence(timeout: 5))
                    app.buttons["Remove"].tap()
                    XCTAssertTrue(app.staticTexts["Saved bookmark"].waitForNonExistence(timeout: 5))
                } else {
                    XCTAssertTrue(app.navigationBars.staticTexts[destination].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
                    let done = app.buttons.matching(NSPredicate(format: "label == 'Done'")).allElementsBoundByIndex.filter(\.isHittable)
                    XCTAssertEqual(done.count, 1, "Only the current sheet owns Done")
                    done.first?.tap()
                }
                XCTAssertTrue(actions.waitForExistence(timeout: 5), "Dismissal returns to the same history row")
            }
            app.terminate()
        }
    }

    @MainActor
    func testDashboardSheetToolbarsTakeTheirTitleTint() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-accessibility-fixture", "-fixture-dashboard"]
        app.launch(); defer { app.terminate() }
        let menu = app.buttons["dashboard.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), app.debugDescription)
        // The Automations sheet's own create, filter and Done actions, then
        // the create flow it opens.
        menu.tap(); app.buttons["Automations"].tap()
        assertToolbarTint(app, title: "Automations")
        app.buttons["automations.new"].tap()
        assertToolbarTint(app, title: "New Automation")
        app.terminate()

        app.launch()
        XCTAssertTrue(menu.waitForExistence(timeout: 10), app.debugDescription)
        menu.tap(); app.buttons["Knowledge"].tap()
        menu.tap(); app.buttons["New note"].tap()
        assertToolbarTint(app, title: "New note")
    }

    @MainActor
    func testManageHomeToolbarsTakeTheirTitleTint() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        let ring = app.buttons["session-context-button"]
        XCTAssertTrue(ring.waitForExistence(timeout: 10))
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: ring)],
                                     timeout: 10) == .completed)
        ring.tap()
        XCTAssertTrue(app.buttons["home-sheet-done-manage"].waitForExistence(timeout: 10), app.debugDescription)
        assertToolbarTint(app, title: "Manage Home")
        let memory = app.descendants(matching: .any)["home-manage-memory-browser"].firstMatch
        XCTAssertTrue(memory.waitForExistence(timeout: 5), app.debugDescription)
        memory.tap()
        XCTAssertTrue(app.buttons["home-sheet-done-memory"].waitForExistence(timeout: 10), app.debugDescription)
        assertToolbarTint(app, title: "Memory")
    }
}
