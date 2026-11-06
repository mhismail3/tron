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
        assertUILock(app, "launch-onboarding-welcome-dark", accessibility: nil)
        app.terminate()
    }

    /// Home's chat with no transcript.
    @MainActor
    func testChatEmpty() throws {
        for mode in Self.modes {
            let app = try openHomeChat(mode: mode)
            // #2093's subtitle tint has no focused successor yet.
            assertUILock(app, "chat-empty-\(mode)", accessibility: nil)
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
            assertUILock(app, "chat-settled-\(mode)", accessibility: nil)
            for _ in 0..<12 where !chip.isHittable { app.swipeUp() }
            chip.tap()
            try require(app.descendants(matching: .any)["home-tool-detail"], in: app)
            assertUILock(app, "chat-tool-sheet-memory-search-\(mode)", accessibility: Self.memorySearchToolSheetTree)
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
            assertUILock(app, "settings-home-\(mode)", accessibility: Self.homeSettingsTree)
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

// MARK: Accessibility witnesses

/// The exact `UILockTree` text of each state with an accessibility witness: every
/// element's type, identifier, label, value, traits, enabled/focus state and
/// whole-point frame, its nesting (two-space indentation) and its order. Light and
/// dark render the same hierarchy, so each state has one expectation for both.
extension TronUILockTests {
    /// Home's global Settings sheet: shared chrome and #1607 source/control metadata.
    static let homeSettingsTree = #"""
        application label="Tron" (0,0 402×874)
          window (0,0 402×874)
            other id="PopoverDismissRegion" label="dismiss popup" (-402,-874 1206×2622)
            other id="PopoverDismissRegion" label="dismiss popup" (-402,-874 1206×2622)
            navigationBar id="_TtGC7SwiftUI32NavigationStackHosting" (8,430 386×52)
              other id="bell" label="Open notifications" value="No unread notifications" (27,434 36×35)
                button id="bell" label="Open notifications" value="No unread notifications" traits=button (27,434 36×35)
              other id="clock.arrow.circlepath" label="Changes" (79,434 36×35)
                button id="clock.arrow.circlepath" label="Changes" traits=button (79,434 36×35)
              staticText label="Global Settings" traits=header,staticText (146,441 109×21)
              other id="settings-done" label="Done" (340,434 35×35)
                button id="settings-done" label="Done" traits=button,selected (346,434 23×35)
            scrollView (8,415 386×451)
              staticText label="This iPhone" traits=header,staticText (27,500 68×16)
              button id="settings-link-Appearance" label="Appearance" traits=button (27,523 348×60)
                image id="circle.lefthalf.filled" label="circle.lefthalf.filled" traits=image (44,547 14×14)
                staticText label="Appearance" traits=staticText (73,535 77×19)
                staticText label="Theme, type scale, and visual preferences" traits=staticText (73,556 233×16)
              button id="settings-link-App Customizations" label="App Customizations" traits=button (27,584 348×60)
                image id="slider.horizontal.2.square" label="slider.horizontal.2.square" traits=image (45,608 12×12)
                staticText label="App Customizations" traits=staticText (73,596 130×19)
                staticText label="Dashboard, visible servers, and subagent activity" traits=staticText (73,617 274×16)
              staticText label="Accounts" traits=header,staticText (27,662 53×16)
              button id="settings-link-Connections" label="Connections" traits=button (27,685 348×60)
                image id="desktopcomputer" label="Computer" traits=image (43,709 16×14)
                staticText label="Connections" traits=staticText (73,697 81×19)
                staticText label="Paired Macs and authorized devices" traits=staticText (73,718 200×16)
              button id="settings-link-Model Providers" label="Model Providers" traits=button (27,746 348×60)
                image id="key" label="Passwords" traits=image (47,768 9×17)
                staticText label="Model Providers" traits=staticText (73,758 107×19)
                staticText label="Provider accounts and sign-in" traits=staticText (73,779 167×16)
              staticText label="Agent & Tools" traits=header,staticText (27,824 77×16)
              button id="settings-link-Agent Behavior" label="Agent Behavior" traits=button (27,848 348×60)
                image id="slider.horizontal.3" label="Edit" traits=image (44,872 14×12)
                staticText label="Agent Behavior" traits=staticText (73,859 100×19)
                staticText label="Models, compaction, trust, and more" traits=staticText (73,881 205×16)
              other id="settings-section-tools-open-leading" label="leading" (41,921 21×21)
              other id="settings-section-tools-open-title" label="title" (73,922 35×19)
              button id="settings-section-tools-open" label="Tools" traits=button (27,909 348×46)
                image id="wrench.and.screwdriver" label="wrench.and.screwdriver" traits=image (43,924 17×16)
                staticText label="Tools" traits=staticText (27,909 348×46)
              button id="settings-link-MCP Servers" label="MCP Servers" traits=button (27,955 348×60)
                image id="server.rack" label="server.rack" traits=image (44,979 16×12)
                staticText label="MCP Servers" traits=staticText (73,967 82×19)
                staticText label="Tool providers and their sign-ins" traits=staticText (73,988 182×16)
              button id="settings-link-Extensions" label="Extensions" traits=button (27,1016 348×60)
                image id="shippingbox" label="Box" traits=image (44,1039 14×15)
                staticText label="Extensions" traits=staticText (73,1027 71×19)
                staticText label="Packages, built-ins, and themes" traits=staticText (73,1049 175×16)
              button id="settings-link-Hooks" label="Hooks" traits=button (27,1077 348×60)
                image id="bolt.horizontal.circle" label="Disconnect" traits=image (44,1100 14×14)
                staticText label="Hooks" traits=staticText (73,1088 41×19)
                staticText label="Event handlers extensions register" traits=staticText (73,1110 194×16)
              staticText label="System" traits=header,staticText (27,1154 41×16)
              button id="settings-link-Mac Terminal" label="Mac Terminal" traits=button (27,1178 348×60)
                image id="apple.terminal" label="apple.terminal" traits=image (44,1202 16×12)
                staticText label="Mac Terminal" traits=staticText (73,1190 90×19)
                staticText label="A shell on your Mac, even without the Gateway" traits=staticText (73,1211 261×16)
              button id="settings-link-Push Notifications" label="Push Notifications" traits=button (27,1239 348×60)
                image id="bell.badge" label="bell.badge" traits=image (45,1262 13×15)
                staticText label="Push Notifications" traits=staticText (73,1250 118×19)
                staticText label="Agent alerts on this iPhone" traits=staticText (73,1272 150×16)
              button id="settings-link-Setup" label="Setup" traits=button (27,1300 348×60)
                image id="gearshape.2" label="Advanced" traits=image (42,1323 19×15)
                staticText label="Setup" traits=staticText (73,1311 37×19)
                staticText label="Import, session storage, telemetry, and prototypes" traits=staticText (73,1333 280×16)
              button id="settings-link-Logs" label="Logs" traits=button (27,1361 348×60)
                image id="text.alignleft" label="Align Left" traits=image (44,1385 14×12)
                staticText label="Logs" traits=staticText (73,1372 30×19)
                staticText label="Diagnostics from this iPhone and your Macs" traits=staticText (73,1393 246×16)
              other label="Vertical scroll bar, 3 pages" value="0%" traits=adjustable (362,482 29×330)
              other label="Vertical scroll bar, 3 pages" value="0%" traits=adjustable (362,482 29×330)
          window (0,0 402×874)

        """#

    /// The memory-search tool detail sheet: shared chrome and #1607 source/control metadata.
    static let memorySearchToolSheetTree = #"""
        application label="Tron" (0,0 402×874)
          window (0,0 402×874)
            other id="PopoverDismissRegion" label="dismiss popup" (-402,-874 1206×2622)
            other id="PopoverDismissRegion" label="dismiss popup" (-402,-874 1206×2622)
            navigationBar id="_TtGC7SwiftUI32NavigationStackHosting" (8,430 386×52)
              other id="info.circle" label="Technical details" (27,434 35×35)
                button id="info.circle" label="Technical details" traits=button (32,434 25×35)
              staticText label="Search memory" traits=header,staticText (143,441 115×21)
              other id="checkmark" label="Done" (340,434 35×35)
                button id="checkmark" label="Done" traits=button,selected (346,434 23×35)
            scrollView (8,415 386×451)
              staticText label="Completed · 42ms" traits=staticText (33,490 119×16)
                image id="checkmark.circle.fill" label="Selected" traits=image,selected (33,492 13×13)
                staticText label="Completed · 42ms" traits=staticText (52,490 100×16)
              other id="home-tool-detail" (23,523 355×413)
                other id="home-tool-header" (23,523 355×60)
                  staticText id="home-tool-outcome" label="“handoff 890”, Messages 1100–end, 2 matches" traits=staticText (23,523 355×60)
                    image id="magnifyingglass" label="Search" traits=image (41,547 13×13)
                    staticText label="“handoff 890”" traits=staticText (69,535 88×19)
                    staticText label="Messages 1100–end" traits=staticText (69,556 107×16)
                    staticText id="home-tool-outcome" label="2 matches" traits=staticText (302,544 64×19)
                staticText id="home-tool-row-Range" label="Range, Messages 1100–1131" traits=staticText (23,601 355×60)
                  image id="text.magnifyingglass" label="text.magnifyingglass" traits=image (41,625 13×13)
                  staticText label="Range" traits=staticText (69,613 41×19)
                  staticText label="Messages 1100–1131" traits=staticText (69,634 111×16)
                staticText id="home-tool-row-Matches" label="Matches, 2" traits=staticText (23,662 355×60)
                  image id="number" label="number" traits=image (41,685 12×13)
                  staticText label="Matches" traits=staticText (69,673 54×19)
                  staticText label="2" traits=staticText (69,695 6×16)
                other id="home-tool-lines-hits" (23,740 355×197)
                  staticText label="Results" traits=header,staticText (23,740 42×16)
                  staticText label="Oldest first." traits=staticText (23,759 65×16)
                  button id="home-tool-line-1110+0" label="Message 1110 · Tool, … the loading pulse: branch feat/890-sheets has unfinished work. Take the claim with scripts/tron work handoff 890." traits=button (23,783 355×92)
                    image id="wrench.and.screwdriver.fill" label="wrench.and.screwdriver.fill" traits=image (39,821 17×16)
                    staticText label="Message 1110 · Tool" traits=staticText (69,795 125×19)
                    staticText label="… the loading pulse: branch feat/890-sheets has unfinished work. Take the claim with scripts/tron work handoff 890." traits=staticText (69,816 296×48)
                  button id="home-tool-line-1131+0" label="Message 1131 · Home, I ran the handoff and the worker resumed." traits=button (23,876 355×60)
                    image id="house.fill" label="Home" traits=image (39,899 16×14)
                    staticText label="Message 1131 · Home" traits=staticText (69,887 136×19)
                    staticText label="I ran the handoff and the worker resumed." traits=staticText (69,909 240×16)
              other label="Vertical scroll bar, 2 pages" value="0%" traits=adjustable (362,482 29×330)
              other label="Vertical scroll bar, 2 pages" value="0%" traits=adjustable (362,482 29×330)
          window (0,0 402×874)

        """#
}
