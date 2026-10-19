import XCTest

/// The locked screen states (plan §6.6): each journey only navigates to a
/// hosted-fixture state and locks it in light and dark. Behavioral assertions
/// stay in the feature journeys; these fail when what the user sees changes.
final class TronUILockTests: XCTestCase {
    private static let modes = ["light", "dark"]

    /// A lock failure records and moves on to the next state; a navigation
    /// failure throws, since every later step would only fail the same way.
    override func setUp() {
        continueAfterFailure = true
    }

    /// The first screen of a fresh install: onboarding's welcome page.
    @MainActor
    func testLaunchOnboardingWelcome() throws {
        for mode in Self.modes {
            let app = launch(["--tron-reset-ui-test-state", "-ApplePersistenceIgnoreState", "YES", "-appearanceMode", mode])
            try require(app.staticTexts["Welcome to Tron"], in: app)
            assertUILock(app, "launch-onboarding-welcome-\(mode)")
            app.terminate()
        }
    }

    /// Home's chat with no transcript.
    @MainActor
    func testChatEmpty() throws {
        for mode in Self.modes {
            let app = try openHomeChat(mode: mode)
            assertUILock(app, "chat-empty-\(mode)")
            app.terminate()
        }
    }

    /// Home's chat with a settled tool transcript, then one tool's detail sheet.
    @MainActor
    func testChatSettledAndToolSheet() throws {
        for mode in Self.modes {
            let app = try openHomeChat(mode: mode, extra: ["-home-tool-transcript"])
            let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Memory search, Completed,")).firstMatch
            try require(chip, in: app)
            assertUILock(app, "chat-settled-\(mode)")
            for _ in 0..<12 where !chip.isHittable { app.swipeUp() }
            chip.tap()
            try require(app.descendants(matching: .any)["home-tool-detail"], in: app)
            assertUILock(app, "chat-tool-sheet-memory-search-\(mode)")
            app.terminate()
        }
    }

    /// Home's Settings gear opens the global Settings sheet.
    @MainActor
    func testHomeSettings() throws {
        for mode in Self.modes {
            let app = try openHomeChat(mode: mode)
            let gear = app.navigationBars.buttons["Settings"]
            try require(gear, in: app)
            gear.tap()
            try require(app.staticTexts["Global Settings"], in: app)
            assertUILock(app, "settings-home-\(mode)")
            app.terminate()
        }
    }

    /// Manage Session's settings for a stopped session, then one row's Value & Source.
    @MainActor
    func testSessionSettingsAndValueSource() throws {
        for mode in Self.modes {
            let app = launch(["-tron-session-configuration-fixture", "-fixture-appearance", mode])
            let stop = app.buttons["Stop session"]
            try require(stop, in: app)
            stop.tap()
            app.buttons["Release terminal settlement"].tap()
            let source = app.buttons["settings-row-model.thinking_role_chat_-source"]
            try require(source, in: app)
            assertUILock(app, "settings-session-\(mode)")
            source.tap()
            try require(app.navigationBars.staticTexts["Value & Source"], in: app)
            assertUILock(app, "settings-value-source-\(mode)")
            app.terminate()
        }
    }

    // MARK: Navigation

    /// Locale and time zone are pinned so dates and numbers render identically.
    @MainActor
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments + ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["TZ"] = "UTC"
        app.launch()
        return app
    }

    @MainActor
    private func require(_ element: XCUIElement, in app: XCUIApplication) throws {
        guard element.waitForExistence(timeout: 10) else {
            throw NavigationFailed(errorDescription: "Navigation did not reach \(element): \(app.debugDescription)")
        }
    }

    private struct NavigationFailed: LocalizedError { let errorDescription: String? }

    @MainActor
    private func openHomeChat(mode: String, extra: [String] = []) throws -> XCUIApplication {
        let app = launch(["-tron-home-dashboard-fixture", "-home-shell-ready"] + extra + (mode == "dark" ? ["-home-dark"] : []))
        let row = app.buttons["home-pinned-row"]
        try require(row, in: app)
        row.tap()
        try require(app.staticTexts["fixture.home-opened-session"], in: app)
        try require(app.navigationBars.staticTexts["Home"], in: app)
        return app
    }
}
