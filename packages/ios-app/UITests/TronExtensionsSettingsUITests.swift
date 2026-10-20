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
}
