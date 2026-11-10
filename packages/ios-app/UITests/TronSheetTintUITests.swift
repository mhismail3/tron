import XCTest

final class TronSheetTintUITests: XCTestCase {
    @MainActor
    func testSettingsSheetToolbarsTakeTheirTitleTint() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-navigation-fixture", "-themeColor", "burgundy"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["settings-link-Connections"].waitForExistence(timeout: 10), app.debugDescription)
        assertToolbarTint(app, title: "Global Settings")
        for title in ["Connections", "MCP Servers", "Appearance"] {
            let link = app.buttons["settings-link-\(title)"]
            for _ in 0..<12 where !link.isHittable { app.swipeUp() }
            let window = app.windows.firstMatch.frame.width
            let icon = CGRect(x: link.frame.minX, y: link.frame.minY, width: 48, height: link.frame.height)
            assertBurgundy(sheetInk(XCUIScreen.main.screenshot().image, icon, window: window), "\(title) row icon")
            link.tap()
            assertToolbarTint(app, title: title)
            let sheetTitle = app.navigationBars.staticTexts.matching(identifier: title).allElementsBoundByIndex.last
            assertBurgundy(sheetTitle.flatMap { sheetInk(XCUIScreen.main.screenshot().image, $0.frame, window: window) },
                           "\(title) sheet title")
            app.buttons.matching(NSPredicate(format: "label == 'Done'")).allElementsBoundByIndex.last(where: \.isHittable)?.tap()
            XCTAssertTrue(app.navigationBars.staticTexts["Global Settings"].firstMatch.waitForExistence(timeout: 5))
            for _ in 0..<12 where !app.buttons["settings-link-Connections"].isHittable { app.swipeDown() }
        }
    }

    private func assertBurgundy(_ ink: [Double]?, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let ink else { return XCTFail("\(context): no inked pixels", file: file, line: line) }
        XCTAssertGreaterThan(ink[0], ink[2], "\(context) \(ink) is not the burgundy theme", file: file, line: line)
        XCTAssertGreaterThan(ink[2], ink[1], "\(context) \(ink) is not the burgundy theme", file: file, line: line)
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
            let sessions = app.buttons["settings-link-Appearance"]
            for _ in 0..<12 where !sessions.isHittable { app.swipeUp() }
            XCTAssertTrue(sessions.isHittable, app.debugDescription)
            sessions.tap()
            let retention = app.buttons["Show finished subagents"]
            XCTAssertTrue(app.navigationBars.staticTexts["Appearance"].waitForExistence(timeout: 5), app.debugDescription)
            for _ in 0..<10 where !retention.isHittable { app.swipeUp() }
            XCTAssertTrue(retention.isHittable, app.debugDescription)
            let previous = retention.value as? String
            XCTAssertNotNil(previous)
            assertToolbarTint(app, title: "Appearance")
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
            XCTAssertTrue(app.navigationBars.staticTexts["Appearance"].waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(retention.waitForExistence(timeout: 5), app.debugDescription)
            for _ in 0..<10 where !retention.isHittable { app.swipeUp() }
            XCTAssertTrue(retention.isHittable, app.debugDescription)
            XCTAssertEqual(retention.value as? String, selected, "The value survives reopening Appearance")
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
            let actions = app.buttons["history-row-fixture-prompt"]
            XCTAssertTrue(actions.waitForExistence(timeout: 10), app.debugDescription)
            assertToolbarTint(app, title: "Session History")
            for (action, destination) in [("Edit From This Prompt", "Edit From This Prompt"),
                                           ("Fork New Session", "Fork Session"), ("Add Bookmark", "Bookmark")] {
                actions.press(forDuration: 1.0)
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
                    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Bookmark retains the native alert’s field autofocus")
                    cancel.tap()
                    actions.press(forDuration: 1.0); app.buttons["Add Bookmark"].tap()
                    let field = app.textFields["Label"]
                    XCTAssertTrue(field.waitForExistence(timeout: 5))
                    field.tap(); field.typeText("Saved bookmark")
                    let entryCapture = XCTAttachment(screenshot: app.screenshot())
                    entryCapture.name = "1261-bookmark-\(appearance)"; entryCapture.lifetime = .keepAlways; add(entryCapture)
                    app.buttons["Save"].tap()
                    XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Saved bookmark'")).firstMatch.waitForExistence(timeout: 5), app.debugDescription)
                    actions.press(forDuration: 1.0); app.buttons["Edit Bookmark"].tap()
                    XCTAssertTrue(app.buttons["Remove"].waitForExistence(timeout: 5))
                    app.buttons["Remove"].tap()
                    XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Saved bookmark'")).firstMatch.waitForNonExistence(timeout: 5))
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
        menu.tap(); app.buttons["Automations"].tap()
        assertToolbarTint(app, title: "Automations")
        app.buttons["automations.new"].tap()
        assertToolbarTint(app, title: "New Automation")
        app.terminate()


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
