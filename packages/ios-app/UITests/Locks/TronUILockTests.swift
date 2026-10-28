import XCTest

/// Remaining visual states (plan §6.6): dark welcome and the light/dark Home,
/// chat and tool-detail states. Behavioral assertions stay in feature journeys;
/// these locks fail when their selected pixel or accessibility witness changes.
final class TronUILockTests: XCTestCase {
    private static let modes = ["light", "dark"]

    /// A lock failure records and moves on to the next state; a navigation
    /// failure throws, since every later step would only fail the same way.
    override func setUp() {
        continueAfterFailure = true
    }

    /// Dark welcome has no equivalent focused appearance check; light retains
    /// the onboarding journey's historical feature-print and control assertions.
    @MainActor
    func testLaunchOnboardingWelcome() throws {
        let app = launch(["--tron-reset-ui-test-state", "-ApplePersistenceIgnoreState", "YES", "-appearanceMode", "dark"])
        try require(app.staticTexts["Welcome to Tron"], in: app)
        assertUILock(app, "launch-onboarding-welcome-dark", accessibility: false)
        app.terminate()
    }

    /// Home's chat with no transcript.
    @MainActor
    func testChatEmpty() throws {
        for mode in Self.modes {
            let app = try openHomeChat(mode: mode)
            // #2093's subtitle tint has no focused successor yet.
            assertUILock(app, "chat-empty-\(mode)", accessibility: false)
            app.terminate()
        }
    }

    /// Home's chat with a settled tool transcript, then one tool's detail sheet.
    @MainActor
    func testChatSettledAndToolSheet() throws {
        for mode in Self.modes {
            let app = try openHomeChat(mode: mode, extra: ["-home-tool-transcript"])
            let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Search memory, Completed,")).firstMatch
            try require(chip, in: app)
            assertUILock(app, "chat-settled-\(mode)", accessibility: false)
            for _ in 0..<12 where !chip.isHittable { app.swipeUp() }
            chip.tap()
            try require(app.descendants(matching: .any)["home-tool-detail"], in: app)
            assertUILock(app, "chat-tool-sheet-memory-search-\(mode)", accessibility: true)
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
            assertUILock(app, "settings-home-\(mode)", accessibility: true)
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
        app.launchEnvironment["TRON_UI_LOCK_RENDERING"] = "1"
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
