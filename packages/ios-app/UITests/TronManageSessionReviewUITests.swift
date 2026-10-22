import XCTest

/// Manage Session, its folded Project section and the Resources sheet (#1655),
/// through the hosted Manage Session fixture with reported usage, a Git
/// workspace and resources of every kind and source. The Capture journeys keep
/// the light/dark review images; the Behavior tests are the regression oracle.
final class TronManageSessionReviewUITests: XCTestCase {
    @MainActor func testCaptureManageSessionLight() { captureManageSession(dark: false) }
    @MainActor func testCaptureManageSessionDark() { captureManageSession(dark: true) }
    @MainActor func testCaptureResourcesLight() { captureResources(dark: false) }
    @MainActor func testCaptureResourcesDark() { captureResources(dark: true) }

    // MARK: Behavior

    /// Manage Session: the usage line sits under the headline with Compact Now
    /// trailing and centered on both; no separate Compact row or toolbar
    /// Terminal; Terminal leads the export card; the renamed rows; no Project
    /// Settings row.
    @MainActor func testManageSessionLayout() {
        let app = launch(dark: false); defer { app.terminate() }
        let card = element(app, "session-usage-summary")
        let headline = element(app, "session-usage-headline"), detail = element(app, "session-usage-detail")
        let compact = app.buttons["manage-session-compact"]
        XCTAssertTrue(headline.exists && detail.exists && compact.exists, card.debugDescription)
        XCTAssertEqual(detail.label, "311K/1M • 31% used")
        XCTAssertEqual(detail.frame.minX, headline.frame.minX, accuracy: 1, "the usage line is left-aligned under the headline")
        XCTAssertGreaterThanOrEqual(detail.frame.minY, headline.frame.maxY - 1, "the usage line is below the headline")
        XCTAssertTrue(card.frame.contains(compact.frame), "Compact Now is inside the usage card: \(compact.frame) vs \(card.frame)")
        XCTAssertGreaterThan(compact.frame.minX, max(headline.frame.maxX, detail.frame.maxX), "Compact Now trails both lines")
        XCTAssertEqual(compact.frame.midY, (headline.frame.minY + detail.frame.maxY) / 2, accuracy: 1.5,
                       "Compact Now is centered on both lines")
        XCTAssertTrue(labels(app, containing: "Compact conversation").isEmpty, "no separate Compact row")
        XCTAssertTrue(app.buttons["manage-session-rename"].exists, "the edit pencil stays")
        for title in ["Workspace", "Instructions", "Resources"] {
            XCTAssertTrue(app.buttons[title].exists, "\(title) row\n\(app.debugDescription)")
        }
        for gone in ["Current Branch", "Agent Instructions", "Project Resources"] {
            XCTAssertTrue(labels(app, containing: gone).isEmpty, "\(gone) is renamed")
        }
        XCTAssertFalse(app.buttons["project-settings-link"].exists, "Project Settings lives in Session Settings")
        let terminal = app.buttons["manage-session-terminal"], html = app.buttons["session-export-html"]
        XCTAssertEqual(app.buttons.matching(identifier: "manage-session-terminal").count, 1)
        XCTAssertGreaterThan(terminal.frame.minY, card.frame.maxY, "Terminal is a row below the usage card, not a toolbar button")
        for _ in 0..<4 where !html.isHittable { app.swipeUp() }
        XCTAssertTrue(terminal.isHittable && html.isHittable, app.debugDescription)
        XCTAssertEqual(terminal.frame.minX, html.frame.minX, accuracy: 1, "Terminal is a row of the export card")
        XCTAssertLessThanOrEqual(terminal.frame.maxY, html.frame.minY + 1, "Terminal is directly above Export as HTML")
        XCTAssertLessThan(html.frame.minY - terminal.frame.maxY, 4, "no other row between Terminal and Export as HTML")
    }

    /// Session Settings ends with the project's section: trust, the ignored
    /// field listed once, a No repository overrides row, and no Workspace row.
    @MainActor func testSessionSettingsShowsProjectSection() {
        let app = launch(dark: false); defer { app.terminate() }
        let link = app.buttons["chat-settings-link"]
        for _ in 0..<12 where !link.isHittable { app.swipeUp() }
        link.tap()
        expandSheet(app, title: "Session Settings")
        let section = element(app, "session-project-settings")
        XCTAssertTrue(section.waitForExistence(timeout: 8), app.debugDescription)
        let none = element(app, "project-settings-no-overrides")
        XCTAssertTrue(none.waitForExistence(timeout: 8), app.debugDescription)
        for _ in 0..<6 where !none.isHittable { app.swipeUp() }
        XCTAssertFalse(labels(none, containing: "No repository overrides").isEmpty, none.debugDescription)
        // A row in the shared card, not the large centered placeholder.
        XCTAssertLessThan(none.frame.height, 140, "No repository overrides is a row: \(none.frame)")
        XCTAssertTrue(section.buttons["project-settings-trust"].exists, section.debugDescription)
        XCTAssertTrue(labels(section, containing: "Workspace").isEmpty, "Manage Session's Workspace row already names the branch")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "settings-ignored-defaultTools").count, 1)
    }

    /// Resources: Global, Project and External tags; a command's and a subagent's
    /// body preview in a glass card, and View All reads the whole of it.
    @MainActor func testResourceTagsAndBodies() {
        for (kind, title, end) in [("commands", "Review", "END OF REVIEW COMMAND"), ("subagents", "Scout", "END OF SCOUT DEFINITION")] {
            let app = launch(dark: false)
            openResources(app)
            XCTAssertTrue(app.staticTexts["Resources"].exists && !app.staticTexts["Project Resources"].exists)
            if kind == "commands" {
                XCTAssertEqual(tags(app, "skills-0"), ["Global"])
                XCTAssertEqual(tags(app, "skills-1"), ["Project"])
                XCTAssertEqual(tags(app, "skills-2"), ["External"])
                XCTAssertEqual(tags(app, "subagents-0"), ["Global"])
                XCTAssertEqual(tags(app, "subagents-1"), ["Project"])
                XCTAssertEqual(tags(app, "prompts-0"), ["Global"], "a global prompt is not tagged Local")
            }
            let row = app.buttons["project-resource-\(kind)-0"]
            for _ in 0..<8 where !row.isHittable { app.swipeUp() }
            row.tap()
            expandSheet(app, title: title)
            let content = element(app, "project-resource-content")
            XCTAssertTrue(content.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertFalse(app.staticTexts["This resource does not expose body content."].exists)
            XCTAssertFalse(app.staticTexts["Content truncated"].exists)
            XCTAssertFalse(labels(content, containing: end).first?.exists ?? false, "the preview is an excerpt")
            let viewAll = app.buttons["project-resource-view-all"]
            XCTAssertTrue(viewAll.exists, app.debugDescription)
            for _ in 0..<4 where !viewAll.isHittable { app.swipeUp() }
            viewAll.tap()
            let reading = element(app, "project-resource-reading")
            XCTAssertTrue(reading.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertFalse(labels(reading, containing: end).isEmpty, "View All shows the whole body\n\(reading.debugDescription)")
            app.terminate()
        }
    }

    // MARK: Journeys

    @MainActor private func launch(dark: Bool) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-configuration-fixture", "-settings-scope-review", "-manage-session-review",
                               "-fixture-appearance", dark ? "dark" : "light"]
        app.launch()
        XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 10))
        app.buttons["Stop session"].tap()
        XCTAssertTrue(element(app, "session-usage-summary").waitForExistence(timeout: 10), app.debugDescription)
        expandSheet(app, title: "Manage Session")
        return app
    }

    @MainActor private func captureManageSession(dark: Bool) {
        let app = launch(dark: dark); defer { app.terminate() }
        let mode = dark ? "dark" : "light"
        shot("manage-session-top-\(mode)")
        for _ in 0..<3 { app.swipeUp() }
        Thread.sleep(forTimeInterval: 0.6)
        shot("manage-session-bottom-\(mode)")
        let link = app.buttons["chat-settings-link"]
        for _ in 0..<12 where !link.isHittable { app.swipeDown() }
        link.tap()
        expandSheet(app, title: "Session Settings")
        XCTAssertTrue(app.buttons["settings-section-model-open"].waitForExistence(timeout: 8), app.debugDescription)
        shot("session-settings-top-\(mode)")
        for _ in 0..<3 { app.swipeUp() }
        Thread.sleep(forTimeInterval: 0.6)
        shot("session-settings-bottom-\(mode)")
        let models = app.buttons["settings-section-model-open"]
        // Back to the top: a row under the top bar still reads as hittable, and
        // a pull past the top would collapse the sheet.
        for _ in 0..<6 where !(models.exists && models.frame.minY > 140) { app.swipeDown() }
        Thread.sleep(forTimeInterval: 0.6)
        models.tap()
        expandSheet(app, title: "Models")
        shot("session-models-\(mode)")
        app.navigationBars.containing(.staticText, identifier: "Models").buttons["Done"].firstMatch.tap()
        _ = waitFor(models, "hittable == true", timeout: 5)
        app.navigationBars.containing(.staticText, identifier: "Session Settings").buttons["Done"].firstMatch.tap()
        // The base build's separate Project Settings sheet, when it still exists.
        let project = app.buttons["project-settings-link"]
        if project.waitForExistence(timeout: 3) {
            _ = waitFor(project, "hittable == true", timeout: 5)
            project.tap()
            expandSheet(app, title: "Project Settings")
            _ = app.staticTexts["No repository overrides"].waitForExistence(timeout: 8)
            shot("project-settings-\(mode)")
        }
    }

    @MainActor private func captureResources(dark: Bool) {
        let mode = dark ? "dark" : "light"
        for (kind, name) in [("commands", "command"), ("subagents", "subagent")] {
            let app = launch(dark: dark)
            openResources(app)
            if kind == "commands" {
                shot("resources-top-\(mode)")
                app.swipeUp()
                Thread.sleep(forTimeInterval: 0.6)
                shot("resources-bottom-\(mode)")
            }
            let row = app.buttons["project-resource-\(kind)-0"]
            for _ in 0..<8 where !row.isHittable { app.swipeUp() }
            row.tap()
            expandSheet(app, title: kind == "commands" ? "Review" : "Scout")
            Thread.sleep(forTimeInterval: 1.0)
            shot("\(name)-detail-\(mode)")
            let viewAll = app.buttons["project-resource-view-all"]
            if viewAll.waitForExistence(timeout: 3) {
                for _ in 0..<4 where !viewAll.isHittable { app.swipeUp() }
                viewAll.tap()
                Thread.sleep(forTimeInterval: 1.5)
                shot("\(name)-reader-\(mode)")
                for _ in 0..<6 { app.swipeUp() }
                Thread.sleep(forTimeInterval: 0.6)
                shot("\(name)-reader-end-\(mode)")
            }
            app.terminate()
        }
    }

    @MainActor private func openResources(_ app: XCUIApplication) {
        let row = app.buttons.matching(NSPredicate(format: "label IN {'Resources', 'Project Resources'}")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), app.debugDescription)
        for _ in 0..<8 where !row.isHittable { app.swipeUp() }
        row.tap()
        XCTAssertTrue(app.buttons["project-resource-skills-0"].waitForExistence(timeout: 10), app.debugDescription)
        expandSheet(app, title: row.label)
    }

    // MARK: Helpers

    /// The distribution and scope tags painted on a Resources row.
    @MainActor private func tags(_ app: XCUIApplication, _ row: String) -> [String] {
        let button = app.buttons["project-resource-\(row)"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), app.debugDescription)
        let words: Set<String> = ["Global", "Project", "External", "Local", "Module", "User"]
        // The row combines its texts into one label; tags are its trailing words.
        return button.label.components(separatedBy: ", ").filter(words.contains)
    }

    @MainActor private func labels(_ root: XCUIElement, containing text: String) -> [XCUIElement] {
        root.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).allElementsBoundByIndex
    }

    /// Brings a sheet to its large detent once it stops presenting.
    @MainActor private func expandSheet(_ app: XCUIApplication, title text: String) {
        let title = app.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 8), app.debugDescription)
        var last = title.frame.minY
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.3)
            if abs(title.frame.minY - last) < 0.5 { break }
            last = title.frame.minY
        }
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        for _ in 0..<3 where title.frame.minY > 120 {
            origin.withOffset(CGVector(dx: 60, dy: title.frame.midY))
                .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: 60, dy: 20)))
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "frame.minY < 120"), object: title)], timeout: 2)
        }
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func waitFor(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 10) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)], timeout: timeout) == .completed
    }

    @MainActor private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
