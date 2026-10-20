import XCTest

/// Global Extensions over the production Settings sheet path, with the
/// Gateway's package shape: five configured Mac packages plus the bundled
/// managed provider `packages.list` appends (#1482).
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
        // Let the list settle so the tap opens the row instead of stopping a scroll.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        link.tap()
        let heading = app.navigationBars.staticTexts["Extensions"].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Built-in Extensions"].waitForExistence(timeout: 10), app.debugDescription)
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

    /// Installed is the one package list: the bundled provider the Gateway appends
    /// is labelled and has no Update/Remove menu, there is no Sources summary row,
    /// and the npm command sits in the Install Package card.
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

        let searchPaths = app.staticTexts["Search paths"]
        for _ in 0..<6 where !(searchPaths.exists && searchPaths.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(searchPaths.exists, app.debugDescription)
        XCTAssertFalse(app.staticTexts["Sources"].exists, "no Sources group: \(app.debugDescription)")
        XCTAssertFalse(app.buttons["settings-row-sources.packages-source"].exists, "no second package summary row")
        let install = app.buttons["Install Package"].firstMatch
        let npm = app.buttons["settings-row-sources.npmCommand-source"]
        XCTAssertTrue(install.exists && npm.exists, app.debugDescription)
        // Same card: the npm row starts where the Install Package row ends,
        // and both precede Search paths.
        XCTAssertEqual(npm.frame.minY, install.frame.maxY, accuracy: 4, "npm command is in the Install Package card: \(app.debugDescription)")
        XCTAssertLessThan(npm.frame.maxY, searchPaths.frame.minY)
    }

    /// Captures the whole sheet, top to the Search paths group, per appearance.
    @MainActor
    func testExtensionsSheetCaptures() {
        for (name, dark, large) in [("light", false, false), ("dark", true, false), ("large", false, true)] {
            let app = openExtensions(dark: dark, large: large)
            let searchPaths = app.staticTexts["Search paths"]
            var reachedEnd = false
            for page in 0..<(large ? 14 : 6) {
                keep(app, "1482-extensions-\(name)-\(page)")
                if reachedEnd { break }
                reachedEnd = searchPaths.exists && searchPaths.isHittable
                app.swipeUp(velocity: .slow)
            }
            app.terminate()
        }
    }

    // MARK: #1491 Default Tools while a built-in extension is off

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
        XCTAssertTrue(app.staticTexts["Default Tools"].waitForExistence(timeout: 10), app.debugDescription)
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

    /// Light and dark at standard text: Mac Tools with Codemode off, its
    /// Value & Source, then Tools after Codemode is turned back on; and a
    /// project's view-only Tools inheriting the Mac's off Codemode.
    @MainActor
    func testDefaultToolsExtensionsOffCaptures() {
        for (name, dark, large) in [("light", false, false), ("dark", true, false)] {
            let app = launchDefaultTools(dark: dark, large: large)
            openTools(app)
            keep(app, "1491-mac-\(name)-off")
            let source = app.buttons["settings-row-tools.active-source"]
            reveal(source, in: app)
            keep(app, "1491-mac-\(name)-off-tools-row")
            source.tap()
            XCTAssertTrue(app.descendants(matching: .any)["settings-provenance-inactive"].waitForExistence(timeout: 10), app.debugDescription)
            keep(app, "1491-mac-\(name)-off-value-source")
            closeTopSheet(app)
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
            let projectSource = project.buttons["settings-row-tools.active-source"]
            reveal(projectSource, in: project)
            keep(project, "1491-project-\(name)-tools")
            projectSource.tap()
            XCTAssertTrue(project.descendants(matching: .any)["settings-provenance-inactive"].waitForExistence(timeout: 10), project.debugDescription)
            keep(project, "1491-project-\(name)-value-source")
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
