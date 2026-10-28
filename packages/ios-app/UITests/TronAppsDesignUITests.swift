import XCTest

/// Proposal-only shared-component journeys. These prove the native composition,
/// not the unimplemented installed-app backend. No goldens or pixel assertions.
final class TronAppsDesignUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testLightDefaultProposal() { review(dark: false, large: false) }
    @MainActor func testDarkDefaultProposal() { review(dark: true, large: false) }
    @MainActor func testLightXXXLProposal() { review(dark: false, large: true) }
    @MainActor func testDarkXXXLProposal() { review(dark: true, large: true) }

    // The approval package excludes the independently reproduced main failure
    // #2086. Full Automations-comparison journeys above remain unchanged.
    @MainActor func testCaptureAppsManageLightDefault() { review(dark: false, large: false, compareAutomations: false) }
    @MainActor func testCaptureAppsManageDarkDefault() { review(dark: true, large: false, compareAutomations: false) }
    @MainActor func testCaptureAppsManageLightXXXL() { review(dark: false, large: true, compareAutomations: false) }
    @MainActor func testCaptureAppsManageDarkXXXL() { review(dark: true, large: true, compareAutomations: false) }

    @MainActor func testSharedRowsOpenRunnerManageAndContinueFeed() {
        let app = launch(dark: false, large: false)
        openProposal(app)
        let row = app.buttons["apps-design-row-habits"]
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        let complete = app.buttons["Complete a habit"]
        XCTAssertTrue(complete.waitForExistence(timeout: 8), app.debugDescription)
        complete.tap()
        XCTAssertTrue(app.staticTexts["Habits completed: 1"].waitForExistence(timeout: 5))
        done(app, title: "Daily habits")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.press(forDuration: 1)
        app.buttons["Manage"].tap()
        let data = app.buttons["apps-design-manage-Data"]
        XCTAssertTrue(data.waitForExistence(timeout: 5))
        data.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Data"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Completed"].firstMatch.exists)
        done(app, title: "Data")
        done(app, title: "Manage Artifact")
        app.buttons["Preview long catalog"].tap()
        let feed = app.scrollViews["apps-design-feed"]
        XCTAssertTrue(feed.waitForExistence(timeout: 5))
        // Scroll through a real shared lazy feed. Its prefetch callback adds
        // at most 20 rows per page; the position pill belongs to TronFeed.
        for _ in 0..<7 {
            if app.buttons["apps-design-row-item-21"].isHittable { break }
            feed.swipeUp()
        }
        XCTAssertTrue(app.buttons["apps-design-row-item-21"].exists, app.debugDescription)
        XCTAssertTrue(app.buttons["feed-position-chip"].exists, app.debugDescription)
        capture("apps-feed-continuation")
        app.terminate()
    }

    @MainActor private func review(dark: Bool, large: Bool, compareAutomations: Bool = true) {
        let suffix = "\(dark ? "dark" : "light")-\(large ? "xxxl" : "default")"
        let app = launch(dark: dark, large: large, expanded: true)
        openProposal(app)
        expand(app, title: "Apps")
        XCTAssertTrue(app.buttons["apps-design-row-habits"].waitForExistence(timeout: 8))
        capture("apps-\(suffix)")
        app.buttons["apps-design-row-habits"].press(forDuration: 1)
        XCTAssertTrue(app.buttons["Manage"].waitForExistence(timeout: 5))
        app.buttons["Manage"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Manage Artifact"].firstMatch.waitForExistence(timeout: 5))
        expand(app, title: "Manage Artifact")
        capture("manage-\(suffix)")
        if large {
            // A large-type still cannot show the whole scrollable destination.
            // Preserve the standard first viewport and also show its real tail.
            app.scrollViews["apps-design-manage-scroll"].swipeUp()
            capture("manage-\(suffix)-continued")
        }
        app.terminate()

        guard compareAutomations else { return }

        // Matching appearance/type size on the actual unchanged Automations
        // surface, not a manually recreated lookalike.
        let automation = XCUIApplication()
        automation.launchArguments = arguments(large: large) + ["-tron-automation-fixture"] + (dark ? ["-automation-dark"] : [])
        automation.launch()
        XCTAssertTrue(automation.buttons["dashboard.menu"].waitForExistence(timeout: 8))
        automation.buttons["dashboard.menu"].tap()
        automation.buttons["Automations"].tap()
        XCTAssertTrue(automation.buttons["automation-card.automation-0"].waitForExistence(timeout: 8))
        expand(automation, title: "Automations")
        capture("automations-\(suffix)")
        automation.terminate()
    }

    @MainActor private func launch(dark: Bool, large: Bool, expanded: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments(large: large) + ["-tron-apps-design-fixture"]
            + (dark ? ["-apps-design-dark"] : []) + (expanded ? ["-apps-design-expanded"] : [])
        app.launch()
        return app
    }
    private func arguments(large: Bool) -> [String] {
        ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-themeColor", "emerald"]
            + (large ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : [])
    }
    @MainActor private func openProposal(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["apps-design-present"].waitForExistence(timeout: 8))
        app.buttons["apps-design-present"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Apps"].firstMatch.waitForExistence(timeout: 8))
    }
    @MainActor private func expand(_ app: XCUIApplication, title: String) {
        let bar = app.navigationBars.containing(.staticText, identifier: title).firstMatch
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
            thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03)))
    }
    @MainActor private func done(_ app: XCUIApplication, title: String) {
        app.navigationBars.containing(.staticText, identifier: title).firstMatch.buttons["Done"].tap()
    }
    @MainActor private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
