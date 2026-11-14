import XCTest

final class TronUILockTests: XCTestCase {
    private static let modes = ["light", "dark"]

    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testChatSettledAndToolSheet() throws {
        for mode in Self.modes {
            let app = try openHomeChat(mode: mode, extra: ["-home-tool-transcript"])
            let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Search memory, Completed,")).firstMatch
            try require(chip, in: app)
            for _ in 0..<12 where !chip.isHittable { app.swipeUp() }
            chip.tap()
            try require(app.descendants(matching: .any)["home-tool-detail"], in: app)
            assertUILock(app, "chat-tool-sheet-memory-search-\(mode)", accessibility: Self.memorySearchToolSheetTree)
            app.terminate()
        }
    }

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

extension TronUILockTests {
    static let homeSettingsTree = #"""
        application label="Tron" (0,0 402×874)
          window (0,0 402×874)
            other id="PopoverDismissRegion" label="dismiss popup" (-402,-874 1206×2622)
            navigationBar id="_TtGC7SwiftUI32NavigationStackHosting" (8,430 386×52)
              button id="bell" label="Open notifications" value="No unread notifications" traits=button (27,434 36×35)
              button id="clock.arrow.circlepath" label="Changes" traits=button (79,434 36×35)
              staticText label="Global Settings" traits=header,staticText (146,441 109×21)
              button id="settings-done" label="Done" traits=button,selected (346,434 23×35)
            scrollView (8,415 386×451)
              staticText label="This iPhone" traits=header,staticText (27,500 68×16)
              button id="settings-link-Appearance" label="Appearance" traits=button (27,523 348×60)
                staticText label="Appearance" traits=staticText (73,535 77×19)
                image id="circle.lefthalf.filled" label="Circle With The Left Half Filled" traits=image (44,547 14×14)
                staticText label="Dashboard, activity, theme, and fonts" traits=staticText (73,556 208×16)
              staticText label="Accounts" traits=header,staticText (27,601 53×16)
              button id="settings-link-Connections" label="Connections" traits=button (27,625 348×60)
                staticText label="Connections" traits=staticText (73,636 81×19)
                image id="desktopcomputer" label="Computer" traits=image (43,648 16×14)
                staticText label="Paired Macs and authorized devices" traits=staticText (73,658 200×16)
              button id="settings-link-Model Providers" label="Model Providers" traits=button (27,685 348×60)
                staticText label="Model Providers" traits=staticText (73,697 107×19)
                image id="key" label="Passwords" traits=image (47,707 9×17)
                staticText label="Provider accounts and sign-in" traits=staticText (73,718 167×16)
              staticText label="Agent & Tools" traits=header,staticText (27,763 77×16)
              button id="settings-link-Agent Behavior" label="Agent Behavior" traits=button (27,787 348×60)
                staticText label="Agent Behavior" traits=staticText (73,798 100×19)
                image id="slider.horizontal.3" label="Edit" traits=image (44,811 14×12)
                staticText label="Models, compaction, trust, and more" traits=staticText (73,820 205×16)
              other id="settings-section-tools-open-leading" label="leading" (41,860 21×21)
              other id="settings-section-tools-open-title" label="title" (73,862 35×19)
              button id="settings-section-tools-open" label="Tools" traits=button (27,848 348×46)
                staticText label="Tools" traits=staticText (27,848 348×46)
                image id="wrench.and.screwdriver" label="Wrench And Screwdriver Crossed" traits=image (43,863 17×16)
              button id="settings-link-MCP Servers" label="MCP Servers" traits=button (27,894 348×60)
                staticText label="MCP Servers" traits=staticText (73,906 82×19)
                image id="server.rack" label="Server Rack" traits=image (44,918 16×12)
                staticText label="Tool providers and their sign-ins" traits=staticText (73,927 182×16)
              button id="settings-link-Extensions" label="Extensions" traits=button (27,955 348×60)
                staticText label="Extensions" traits=staticText (73,967 71×19)
                image id="shippingbox" label="Box" traits=image (44,978 14×15)
                staticText label="Packages, built-ins, and themes" traits=staticText (73,988 175×16)
              button id="settings-link-Hooks" label="Hooks" traits=button (27,1016 348×60)
                staticText label="Hooks" traits=staticText (73,1027 41×19)
                image id="bolt.horizontal.circle" label="Disconnect" traits=image (44,1039 14×14)
                staticText label="Event handlers extensions register" traits=staticText (73,1049 194×16)
              staticText label="System" traits=header,staticText (27,1094 41×16)
              button id="settings-link-Mac Terminal" label="Mac Terminal" traits=button (27,1117 348×60)
                staticText label="Mac Terminal" traits=staticText (73,1129 90×19)
                image id="apple.terminal" label="Terminal Command-Line Prompt" traits=image (44,1141 16×12)
                staticText label="A shell on your Mac, even without the Gateway" traits=staticText (73,1150 261×16)
              button id="settings-link-Push Notifications" label="Push Notifications" traits=button (27,1178 348×60)
                staticText label="Push Notifications" traits=staticText (73,1190 118×19)
                image id="bell.badge" label="Bell With A Notification Badge" traits=image (45,1201 13×15)
                staticText label="Agent alerts on this iPhone" traits=staticText (73,1211 150×16)
              button id="settings-link-Setup" label="Setup" traits=button (27,1239 348×60)
                staticText label="Setup" traits=staticText (73,1250 37×19)
                image id="gearshape.2" label="Advanced" traits=image (42,1262 19×15)
                staticText label="Import, session storage, telemetry, and prototypes" traits=staticText (73,1272 280×16)
              other label="Vertical scroll bar, 3 pages" value="0%" traits=adjustable (362,482 29×332)
              other label="Vertical scroll bar, 3 pages" value="0%" traits=adjustable (362,482 29×332)
            toolbar id="Toolbar" label="Toolbar" (8,415 386×451)
          window (0,0 402×874)

        """#

    static let memorySearchToolSheetTree = #"""
        application label="Tron" (0,0 402×874)
          window (0,0 402×874)
            other id="PopoverDismissRegion" label="dismiss popup" (-402,-874 1206×2622)
            navigationBar id="_TtGC7SwiftUI32NavigationStackHosting" (8,430 386×52)
              button id="info.circle" label="Technical details" traits=button (32,434 25×35)
              staticText label="Search memory" traits=header,staticText (143,441 115×21)
              button id="checkmark" label="Done" traits=button,selected (346,434 23×35)
            scrollView (8,415 386×451)
              staticText label="Completed · 42ms" traits=staticText (23,484 137×28)
                staticText label="Completed · 42ms" traits=staticText (23,484 137×28)
                image id="checkmark.circle.fill" label="Selected" traits=image,selected (33,492 13×13)
              other id="home-tool-detail" (23,523 355×413)
                other id="home-tool-header" (23,523 355×60)
                  staticText id="home-tool-outcome" label="“handoff 890”, Messages 1100–end, 2 matches" traits=staticText (23,523 355×60)
                    staticText label="“handoff 890”" traits=staticText (69,535 88×19)
                    image id="magnifyingglass" label="Search" traits=image (41,547 13×13)
                    staticText id="home-tool-outcome" label="2 matches" traits=staticText (302,544 64×19)
                    staticText label="Messages 1100–end" traits=staticText (69,556 107×16)
                staticText id="home-tool-row-Range" label="Range, Messages 1100–1131" traits=staticText (23,601 355×60)
                  staticText label="Range" traits=staticText (69,613 41×19)
                  image id="text.magnifyingglass" label="Text With A Magnifying Glass" traits=image (41,625 13×13)
                  staticText label="Messages 1100–1131" traits=staticText (69,634 111×16)
                staticText id="home-tool-row-Matches" label="Matches, 2" traits=staticText (23,662 355×60)
                  staticText label="Matches" traits=staticText (69,673 54×19)
                  image id="number" label="Number Sign" traits=image (41,685 12×13)
                  staticText label="2" traits=staticText (69,695 6×16)
                other id="home-tool-lines-hits" (23,740 355×197)
                  staticText label="Results" traits=header,staticText (23,740 42×16)
                  staticText label="Oldest first." traits=staticText (23,759 65×16)
                  button id="home-tool-line-1110+0" label="Message 1110 · Tool, … the loading pulse: branch feat/890-sheets has unfinished work. Take the claim with scripts/tron work handoff 890." traits=button (23,783 355×92)
                    staticText label="Message 1110 · Tool" traits=staticText (69,795 125×19)
                    image id="wrench.and.screwdriver.fill" label="Wrench And Screwdriver, Filled" traits=image (39,821 17×16)
                    staticText label="… the loading pulse: branch feat/890-sheets has unfinished work. Take the claim with scripts/tron work handoff 890." traits=staticText (69,816 296×48)
                  button id="home-tool-line-1131+0" label="Message 1131 · Home, I ran the handoff and the worker resumed." traits=button (23,876 355×60)
                    staticText label="Message 1131 · Home" traits=staticText (69,887 136×19)
                    image id="house.fill" label="Home" traits=image (39,899 16×14)
                    staticText label="I ran the handoff and the worker resumed." traits=staticText (69,909 240×16)
              other label="Vertical scroll bar, 2 pages" value="0%" traits=adjustable (362,482 29×332)
              other label="Vertical scroll bar, 2 pages" value="0%" traits=adjustable (362,482 29×332)
            toolbar id="Toolbar" label="Toolbar" (8,415 386×451)
          window (0,0 402×874)

        """#
}
