import Vision
import XCTest

/// Overridden rows in Home, Session and Project settings at their reported
/// lengths (#1651), through the hosted Home and Manage Session fixtures: values
/// paint in full beside a title-line Overridden pill and a separate Revert,
/// Session and Home use Global's group cards, ignored repository fields are
/// listed once (Project Settings) in plain language, and summaries skip unset values.
final class TronSettingsScopeRowsUITests: XCTestCase {
    @MainActor func testHomeModelsLight() { homeModels(dark: false) }
    @MainActor func testHomeModelsDark() { homeModels(dark: true) }
    @MainActor func testSessionAndProjectLight() { sessionAndProject(dark: false) }
    @MainActor func testSessionAndProjectDark() { sessionAndProject(dark: true) }

    @MainActor private func homeModels(dark: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-settings-scope-review"] + (dark ? ["-home-dark"] : [])
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 15))
        app.buttons["home-pinned-row"].tap()
        let ring = app.buttons["session-context-button"]
        XCTAssertTrue(ring.waitForExistence(timeout: 15))
        XCTAssertTrue(waitFor(ring, "enabled == true"))
        ring.tap()
        let row = element(app, "home-manage-settings")
        XCTAssertTrue(row.waitForExistence(timeout: 8), app.debugDescription)
        for _ in 0..<8 where !row.isHittable { app.swipeUp() }
        row.tap()
        expandSheet(app, title: "Home Settings")
        let models = app.buttons["settings-section-model-open"]
        XCTAssertTrue(models.waitForExistence(timeout: 8), app.debugDescription)
        shot("1651-home-settings-\(dark ? "dark" : "light")")
        models.tap()
        expandSheet(app, title: "Models")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'settings-row-model.ref'"))
            .firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        shot("1651-home-models-\(dark ? "dark" : "light")")
        assertOverriddenRow(app, "settings-row-model.ref_role_chat_", title: "Model", value: #"^Claude Opus 5\.5$"#)
        assertOverriddenRow(app, "settings-row-model.queue_role_worker_", title: "Worker models", value: "^2 models$")
        assertOverriddenRow(app, "settings-row-model.queue_role_subagent_", title: "Subagent models", value: "^3 models$")
        app.swipeUp()
        shot("1651-home-models-\(dark ? "dark" : "light")-bottom")
        assertOverriddenRow(app, "settings-row-model.queue_role_background_", title: "Background models", value: "^3 models$")
    }

    @MainActor private func sessionAndProject(dark: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-configuration-fixture", "-settings-scope-review",
                               "-fixture-appearance", dark ? "dark" : "light"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 10))
        app.buttons["Stop session"].tap()
        let link = app.buttons["chat-settings-link"]
        for _ in 0..<12 where !link.isHittable { app.swipeUp() }
        link.tap()
        expandSheet(app, title: "Session Settings")
        let toolsLink = app.buttons["settings-section-tools-open"]
        XCTAssertTrue(toolsLink.waitForExistence(timeout: 8), app.debugDescription)
        shot("1651-session-settings-\(dark ? "dark" : "light")")
        let content = element(app, "session-settings-content")
        // Global Settings' groups of drill-in rows, not inline editors.
        XCTAssertTrue(content.staticTexts["Agent"].exists, content.debugDescription)
        XCTAssertTrue(content.staticTexts["Tools & Extensions"].exists, content.debugDescription)
        XCTAssertFalse(element(app, "settings-row-tools.active").exists, "Tools opens from its row")
        // The ignored repository field is Project Settings' to list, once.
        XCTAssertEqual(labels(content, containing: "Ignored").count, 0, content.debugDescription)
        XCTAssertEqual(labels(content, containing: "tools.active").count, 0, content.debugDescription)
        // The unset context window is not part of what the chat uses.
        XCTAssertEqual(labels(content, containing: "Not set").count, 0, content.debugDescription)
        XCTAssertGreaterThan(labels(content, containing: "Claude Opus 5.5 · High").count, 0, content.debugDescription)
        toolsLink.tap()
        expandSheet(app, title: "Tools")
        XCTAssertTrue(element(app, "settings-row-tools.active").waitForExistence(timeout: 8), app.debugDescription)
        shot("1651-session-tools-\(dark ? "dark" : "light")")
        assertOverriddenRow(app, "settings-row-tools.active", title: "Tools", value: "^27 of 52 tools$")
        app.navigationBars.containing(.staticText, identifier: "Tools").buttons["Done"].firstMatch.tap()
        let modelsLink = app.buttons["settings-section-model-open"]
        XCTAssertTrue(modelsLink.waitForExistence(timeout: 5), app.debugDescription)
        _ = waitFor(modelsLink, "hittable == true", timeout: 5)
        modelsLink.tap()
        expandSheet(app, title: "Models")
        shot("1651-session-models-\(dark ? "dark" : "light")")
        app.navigationBars.containing(.staticText, identifier: "Models").buttons["Done"].firstMatch.tap()
        _ = waitFor(modelsLink, "hittable == true", timeout: 5)
        app.navigationBars.containing(.staticText, identifier: "Session Settings").buttons["Done"].firstMatch.tap()
        let project = app.buttons["project-settings-link"]
        XCTAssertTrue(project.waitForExistence(timeout: 5), app.debugDescription)
        // The pop back to Manage Session settles before its rows take taps.
        _ = waitFor(project, "hittable == true", timeout: 5)
        for _ in 0..<4 where !project.isHittable { app.swipeUp() }
        for _ in 0..<8 where !project.isHittable { app.swipeDown() }
        project.tap()
        expandSheet(app, title: "Project Settings")
        _ = app.staticTexts["No repository overrides"].waitForExistence(timeout: 8)
        shot("1651-project-settings-\(dark ? "dark" : "light")")
        let ignored = element(app, "settings-ignored-defaultTools")
        XCTAssertTrue(ignored.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(ignored.label.contains("Tools") && ignored.label.contains("Project settings can't change this"), ignored.label)
        XCTAssertFalse(ignored.label.contains("tools.active"), ignored.label)
    }

    /// An overridden row: the value paints whole, the Overridden pill sits on the
    /// title's line before the value, and Revert stays its own 44-point target.
    @MainActor private func assertOverriddenRow(_ app: XCUIApplication, _ prefix: String, title: String, value pattern: String,
                                                file: StaticString = #filePath, line: UInt = #line) {
        let row = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND NOT identifier ENDSWITH '-reset'", prefix)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(prefix)\n\(app.debugDescription)", file: file, line: line)
        let editor = row.buttons.matching(NSPredicate(format: "label == %@ AND NOT identifier ENDSWITH '-reset'", title)).firstMatch
        let pill = row.staticTexts["Overridden"], heading = row.staticTexts[title].firstMatch
        let revert = row.buttons.matching(NSPredicate(format: "identifier ENDSWITH '-reset'")).firstMatch
        XCTAssertTrue(editor.exists && pill.exists && heading.exists && revert.exists, row.debugDescription, file: file, line: line)
        XCTAssertLessThanOrEqual(pill.frame.maxX, editor.frame.minX, "\(title): Overridden precedes the value", file: file, line: line)
        XCTAssertEqual(pill.frame.midY, heading.frame.midY, accuracy: 8, "\(title): Overridden is on the title line", file: file, line: line)
        XCTAssertGreaterThanOrEqual(revert.frame.minX, editor.frame.maxX, "\(title): Revert follows the value", file: file, line: line)
        XCTAssertGreaterThanOrEqual(revert.frame.width, 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(revert.frame.height, 44, file: file, line: line)
        assertRendersWhole(editor, matching: pattern, named: "1651-\(prefix)-value", file: file, line: line)
    }

    /// The element's painted text, recognized from pixels: a truncated pill keeps
    /// its full accessibility label, so only the glyphs show an ellipsis.
    @MainActor private func assertRendersWhole(_ element: XCUIElement, matching pattern: String, named name: String,
                                               file: StaticString, line: UInt) {
        let screenshot = element.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let image = screenshot.image.cgImage else { return XCTFail("No pixels for \(name)", file: file, line: line) }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        XCTAssertNoThrow(try VNImageRequestHandler(cgImage: image).perform([request]), file: file, line: line)
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ").trimmingCharacters(in: .whitespaces)
        XCTAssertNotNil(text.range(of: pattern, options: .regularExpression), "\(name) rendered \"\(text)\", expected \(pattern)",
                        file: file, line: line)
    }

    @MainActor private func labels(_ root: XCUIElement, containing text: String) -> [XCUIElement] {
        root.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).allElementsBoundByIndex
    }

    /// Brings a settings sheet to its large detent once it stops presenting.
    @MainActor private func expandSheet(_ app: XCUIApplication, title text: String) {
        let title = app.navigationBars.staticTexts[text].firstMatch
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
