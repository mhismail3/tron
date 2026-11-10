import Vision
import XCTest

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
        XCTAssertFalse(app.buttons["settings-section-model-open"].exists, "Home's first-level Models route is removed")
        XCTAssertTrue(element(app, "settings-row-model.queue_role_worker_").waitForExistence(timeout: 8), app.debugDescription)
        shot("1651-home-settings-\(dark ? "dark" : "light")")
        shot("1651-home-models-\(dark ? "dark" : "light")")
        assertOverriddenRow(app, "settings-row-model.queue_role_worker_", title: "Worker models", value: "^2 models$")
        assertOverriddenRow(app, "settings-row-model.queue_role_subagent_", title: "Subagent models", value: "^3 models$")
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
        let sections = element(app, "session-project-settings")
        XCTAssertFalse(sections.staticTexts["Settings"].exists, "The session card is untitled")
        XCTAssertTrue(sections.buttons["settings-section-tools-open"].exists, sections.debugDescription)
        XCTAssertFalse(element(app, "settings-row-tools.active").exists, "Tools opens from its row")
        XCTAssertEqual(labels(content, containing: "Ignored").count, 0, content.debugDescription)
        XCTAssertEqual(labels(content, containing: "tools.active").count, 0, content.debugDescription)
        XCTAssertEqual(labels(content, containing: "Not set").count, 0, content.debugDescription)
        toolsLink.tap()
        expandSheet(app, title: "Tools")
        XCTAssertTrue(element(app, "settings-row-tools.active").waitForExistence(timeout: 8), app.debugDescription)
        shot("1651-session-tools-\(dark ? "dark" : "light")")
        assertOverriddenRow(app, "settings-row-tools.active", title: "Tools", value: "^27 of 52 tools$")
        app.navigationBars.containing(.staticText, identifier: "Tools").buttons["Done"].firstMatch.tap()
        XCTAssertFalse(app.buttons["settings-section-model-open"].exists,
                       "The direct model/thinking card belongs to Manage Session; this fixture has no delegation overrides")
        let projectSection = element(app, "session-project-settings")
        XCTAssertTrue(projectSection.waitForExistence(timeout: 8), app.debugDescription)
        for _ in 0..<6 where !app.staticTexts["No repository overrides"].isHittable { app.swipeUp() }
        shot("1651-project-settings-\(dark ? "dark" : "light")")
        let ignored = element(app, "settings-ignored-defaultTools")
        XCTAssertTrue(ignored.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(ignored.label.contains("Tools") && ignored.label.contains("Project settings can't change this"), ignored.label)
        XCTAssertFalse(ignored.label.contains("tools.active"), ignored.label)
    }

    @MainActor private func assertOverriddenRow(_ app: XCUIApplication, _ prefix: String, title: String, value pattern: String,
                                                file: StaticString = #filePath, line: UInt = #line) {
        let row = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND NOT identifier ENDSWITH '-reset'", prefix)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(prefix)\n\(app.debugDescription)", file: file, line: line)
        let editor = row.buttons.matching(NSPredicate(format: "label == %@ AND NOT identifier ENDSWITH '-reset'", title)).firstMatch
        if prefix.contains("model.queue") {
            XCTAssertEqual(row.buttons.count, 2, "A queue override has one list editor and a separate Revert", file: file, line: line)
        }
        let pill = row.staticTexts["Overridden"], heading = row.staticTexts[title].firstMatch
        let revert = row.buttons.matching(NSPredicate(format: "identifier ENDSWITH '-reset'")).firstMatch
        XCTAssertTrue(editor.exists && pill.exists && heading.exists && revert.exists, row.debugDescription, file: file, line: line)
        XCTAssertLessThanOrEqual(pill.frame.maxX, editor.frame.minX, "\(title): Overridden precedes the value", file: file, line: line)
        XCTAssertGreaterThan(pill.frame.minX, heading.frame.minX, "\(title): Overridden follows the title", file: file, line: line)
        let lines = max(1, (heading.frame.height / pill.frame.height).rounded())
        XCTAssertEqual(pill.frame.midY, heading.frame.minY + heading.frame.height / lines / 2, accuracy: 0.75,
                       "\(title): Overridden is centered on the title line: \(pill.frame) vs \(heading.frame)", file: file, line: line)
        XCTAssertLessThanOrEqual(revert.frame.maxX, editor.frame.minX + 0.001, "\(title): Revert precedes the value", file: file, line: line)
        XCTAssertGreaterThanOrEqual(revert.frame.width, 43.5, "\(title): Revert keeps a 44-point target", file: file, line: line)
        XCTAssertGreaterThanOrEqual(revert.frame.height, 43.5, "\(title): Revert keeps a 44-point target", file: file, line: line)
        assertRendersWhole(editor, matching: pattern, named: "1651-\(prefix)-value", file: file, line: line)
    }

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
