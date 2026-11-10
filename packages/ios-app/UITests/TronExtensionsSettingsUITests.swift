import XCTest

final class TronExtensionsSettingsUITests: XCTestCase {
    @MainActor
    private func openExtensions(dark: Bool = false, large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-ui-extensions",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if dark { app.launchArguments.append("-settings-renderer-dark") }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"] }
        app.launch()
        let link = app.buttons["settings-link-Extensions"]
        XCTAssertTrue(link.waitForExistence(timeout: 15), app.debugDescription)
        for _ in 0..<8 where !link.isHittable { app.swipeUp(velocity: .slow) }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        link.tap()
        let heading = app.navigationBars.staticTexts["Extensions"].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.switches["Codemode"].waitForExistence(timeout: 10), app.debugDescription)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        return app
    }

    @MainActor
    private func keep(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testInstalledIsTheOnePackageList() {
        let app = openExtensions()
        defer { app.terminate() }
        let rows = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@ OR label ENDSWITH %@", ". Global", ". Bundled with Tron"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(rows.count, 6, "five configured packages and the bundled provider: \(app.debugDescription)")
        let bundled = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "tron:pi-subagents")).firstMatch
        XCTAssertTrue(bundled.exists, app.debugDescription)
        XCTAssertTrue(bundled.label.hasSuffix(". Bundled with Tron"), "bundled row label: \(bundled.label)")
        XCTAssertFalse(bundled.buttons["More"].exists, "the bundled provider has no Update/Remove menu")

        let searchPaths = app.descendants(matching: .any)["settings-row-sources.extensions"]
        for _ in 0..<6 where !(searchPaths.exists && searchPaths.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(searchPaths.exists, app.debugDescription)
        XCTAssertFalse(app.staticTexts["Sources"].exists, "no Sources group: \(app.debugDescription)")
        XCTAssertFalse(app.descendants(matching: .any)["settings-row-sources.packages"].exists, "no second package summary row")
        XCTAssertFalse(app.buttons["Install Package"].exists, "no native install form: \(app.debugDescription)")
        let npm = app.descendants(matching: .any)["settings-row-sources.npmCommand"]
        XCTAssertTrue(npm.exists, app.debugDescription)
        XCTAssertLessThan(npm.frame.maxY, searchPaths.frame.minY)
    }

    @MainActor
    private func launchDefaultTools(project: Bool = false, dark: Bool = false, large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-ui-extensions", "-settings-ui-tools-write",
                               "-settings-ui-builtin-off", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if project { app.launchArguments.append("-settings-ui-project-tools") }
        if dark { app.launchArguments.append("-settings-renderer-dark") }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"] }
        app.launch()
        return app
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<10 where !element.isHittable { app.swipeUp(velocity: .slow) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    @MainActor
    private func openTools(_ app: XCUIApplication) {
        let tools = app.buttons["settings-section-tools-open"]
        reveal(tools, in: app)
        tools.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Tools the agent has in every new session")).firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }

    @MainActor
    private func closeTopSheet(_ app: XCUIApplication) {
        let done = app.buttons.matching(NSPredicate(format: "label == %@", "Done")).allElementsBoundByIndex.last { $0.isHittable }
        XCTAssertNotNil(done, app.debugDescription)
        done?.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }

    @MainActor
    private func codemodeDefault(_ app: XCUIApplication) -> XCUIElement {
        app.switches.matching(NSPredicate(format: "label == %@", "Always include codemode")).firstMatch
    }

    @MainActor
    func testDefaultToolsInactiveWhileBuiltinExtensionOff() {
        continueAfterFailure = false
        let app = launchDefaultTools()
        defer { app.terminate() }
        openTools(app)
        let toggle = codemodeDefault(app)
        reveal(toggle, in: app)
        XCTAssertFalse(toggle.isEnabled, "Codemode is off in Extensions: \(app.debugDescription)")
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertTrue(app.switches["Always include tool search"].isEnabled, "Tool search still loads")
        toggle.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertEqual(app.staticTexts["fixture.settings-renderer-applied"].label, "applied:0", "An inactive switch writes nothing")
        XCTAssertEqual(app.staticTexts["fixture.tools-write"].label, "none")
        closeTopSheet(app)

        let extensions = app.buttons["settings-link-Extensions"]
        reveal(extensions, in: app)
        extensions.tap()
        let codemode = app.switches["Codemode"]
        XCTAssertTrue(codemode.waitForExistence(timeout: 10), app.debugDescription)
        codemode.tap()
        XCTAssertTrue(waitForValue(codemode, "1"), app.debugDescription)
        closeTopSheet(app)
        openTools(app)
        reveal(toggle, in: app)
        XCTAssertTrue(toggle.isEnabled, app.debugDescription)
        XCTAssertEqual(toggle.value as? String, "1", "The kept +codemode shows again")
        XCTAssertEqual(app.staticTexts["fixture.tools-write"].label, "none", "tools.active was never rewritten")
    }

    @MainActor
    func testDefaultToolsExtensionsOffCaptures() {
        for (name, dark, large) in [("light", false, false), ("dark", true, false)] {
            let app = launchDefaultTools(dark: dark, large: large)
            openTools(app)
            keep(app, "1491-mac-\(name)-off")
            let row = app.descendants(matching: .any)["settings-row-tools.active"]
            reveal(row, in: app)
            keep(app, "1491-mac-\(name)-off-tools-row")
            closeTopSheet(app)
            let extensions = app.buttons["settings-link-Extensions"]
            reveal(extensions, in: app)
            extensions.tap()
            let codemode = app.switches["Codemode"]
            XCTAssertTrue(codemode.waitForExistence(timeout: 10), app.debugDescription)
            codemode.tap()
            XCTAssertTrue(waitForValue(codemode, "1"), app.debugDescription)
            closeTopSheet(app)
            openTools(app)
            keep(app, "1491-mac-\(name)-on")
            app.terminate()

            let project = launchDefaultTools(project: true, dark: dark, large: large)
            let projectRow = project.descendants(matching: .any)["settings-row-tools.active"]
            reveal(projectRow, in: project)
            keep(project, "1491-project-\(name)-tools")
            project.terminate()
        }
    }

    @MainActor
    private func waitForValue(_ element: XCUIElement, _ value: String, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.value as? String == value { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return element.value as? String == value
    }
}
