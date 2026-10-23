import XCTest

/// Manage Session, Manage Home and the sheets they open share one emerald sheet
/// theme; each sub-sheet is titled by the row that opens it; Instructions rows
/// keep their summary on the title's line (#1680). The Capture journeys keep the
/// light/dark review images; the Behavior tests are the regression oracle.
final class TronManageSheetsThemeUITests: XCTestCase {
    @MainActor func testCaptureManageSessionSheets() {
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            let app = launchManageSession(dark: dark); defer { app.terminate() }
            shot("manage-session-top-\(mode)")
            open(app, row: "Workspace")
            shot("workspace-\(mode)")
            closeTop(app)
            open(app, row: "Resources")
            shot("resources-\(mode)")
            closeTop(app)
            open(app, row: "Instructions")
            shot("instructions-from-manage-session-\(mode)")
            closeTop(app)
            app.terminate()
        }
    }

    @MainActor func testCaptureManageHomeSheets() {
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            let app = launchManageHome(dark: dark); defer { app.terminate() }
            shot("manage-home-top-\(mode)")
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.6)
            shot("manage-home-bottom-\(mode)")
            app.swipeDown()
            Thread.sleep(forTimeInterval: 0.6)
            for (row, done) in [("home-manage-memory-browser", "home-sheet-done-memory"),
                                ("home-manage-profile", "home-sheet-done-profile")] {
                element(app, row).tap()
                expand(app, done: done)
                Thread.sleep(forTimeInterval: 0.8)
                shot("\(row.replacingOccurrences(of: "home-manage-", with: "home-"))-\(mode)")
                app.buttons[done].tap()
                Thread.sleep(forTimeInterval: 0.6)
            }
        }
    }

    @MainActor func testCaptureInstructions() {
        for (name, arguments) in [("light", [String]()), ("dark", ["-home-dark"]),
                                  ("xxxl-light", ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])] {
            let app = launchInstructions(arguments); defer { app.terminate() }
            expand(app, title: app.navigationBars.staticTexts.firstMatch.label)
            Thread.sleep(forTimeInterval: 0.6)
            shot("instructions-\(name)")
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.6)
            shot("instructions-\(name)-bottom")
            if name.hasPrefix("xxxl") {
                for page in 2...4 {
                    app.swipeUp()
                    Thread.sleep(forTimeInterval: 0.6)
                    shot("instructions-\(name)-bottom\(page)")
                }
            }
            app.buttons["agent-instructions-full-prompt"].firstMatch.tap()
            Thread.sleep(forTimeInterval: 1.2)
            shot("instructions-full-prompt-\(name)")
            closeTop(app)
            Thread.sleep(forTimeInterval: 0.6)
            let tools = app.buttons["agent-instructions-section-tools"]
            for _ in 0..<4 where !tools.isHittable { app.swipeDown() }
            tools.tap()
            Thread.sleep(forTimeInterval: 1.2)
            shot("instructions-tools-section-\(name)")
            app.terminate()
        }
    }

    // MARK: Behavior

    /// Each editor is the first interaction on a newly opened Home model card.
    @MainActor func testFirstOpenHomeEffortAndContextExposeUsableSliders() {
        for (control, slider) in [("settings-choice-control", "settings-choice-slider"),
                                  ("settings-number-control", "settings-number-slider")] {
            let app = launchManageHome(dark: false)
            defer { app.terminate() }
            let button = app.buttons[control].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 8), app.debugDescription)
            button.tap()
            let editor = app.descendants(matching: .any)[slider].firstMatch
            XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(editor.isHittable, "First-open editor must accept input, not remain an empty capsule")
            XCTAssertGreaterThan(editor.frame.width, 150)
            shot("first-open-\(control)")
            app.terminate()
        }
    }

    /// Each Manage Session row opens a sheet titled with the row's own label, and
    /// the row's icon and that title are inked in Manage Session's emerald title
    /// color: one sheet theme, no per-row teal.
    @MainActor func testManageSessionRowsTitleTheirSheetsInTheSheetTheme() {
        for dark in [false, true] {
            let app = launchManageSession(dark: dark); defer { app.terminate() }
            let mode = dark ? "dark" : "light"
            let theme = ink(app, navigationTitle(app, "Manage Session"))
            for label in ["Workspace", "Instructions", "Resources", "Session History", "Subagent History"] {
                let row = app.buttons[label].firstMatch
                XCTAssertTrue(row.waitForExistence(timeout: 8), app.debugDescription)
                for _ in 0..<6 where !row.isHittable { app.swipeUp() }
                assertInk(ink(app, row, leading: 56), theme, "\(label) row icon (\(mode))")
                row.tap()
                let title = navigationTitle(app, label)
                XCTAssertTrue(title.waitForExistence(timeout: 8), "\(label) opens a sheet titled \(label)\n\(app.debugDescription)")
                _ = waitFor(title, "hittable == true", timeout: 3)
                assertInk(ink(app, title), theme, "\(label) sheet title (\(mode))")
                closeTop(app)
            }
        }
    }

    /// Each Manage Home row opens a sheet titled with the row's title, inked in
    /// Manage Home's own emerald.
    @MainActor func testManageHomeRowsTitleTheirSheetsInTheSheetTheme() {
        let app = launchManageHome(dark: false); defer { app.terminate() }
        let theme = ink(app, navigationTitle(app, "Manage Home"))
        for (id, done) in [("home-manage-profile", "home-sheet-done-profile"), ("home-manage-memory-browser", "home-sheet-done-memory"),
                           ("home-manage-chapters", "home-sheet-done-chapters"), ("home-manage-tasks", "home-sheet-done-tasks")] {
            let row = element(app, id)
            XCTAssertTrue(row.waitForExistence(timeout: 8), app.debugDescription)
            for _ in 0..<4 where !row.isHittable { app.swipeUp() }
            let label = row.label.components(separatedBy: ", ").first ?? row.label
            assertInk(ink(app, row, leading: 56), theme, "\(label) row icon")
            row.tap()
            XCTAssertTrue(app.buttons[done].waitForExistence(timeout: 8), app.debugDescription)
            let title = navigationTitle(app, label)
            XCTAssertTrue(title.waitForExistence(timeout: 5), "\(id) opens a sheet titled \(label)\n\(app.debugDescription)")
            _ = waitFor(title, "hittable == true", timeout: 3)
            assertInk(ink(app, title), theme, "\(label) sheet title")
            app.buttons[done].tap()
            Thread.sleep(forTimeInterval: 0.6)
        }
    }

    /// Instructions rows are one line: the summary trails the title on its line,
    /// every row's number is inked in the sheet's title color, and the per-turn
    /// section keeps its Each turn tag. At XXXL the summary reads whole.
    @MainActor func testInstructionsRowsKeepTheirSummaryOnTheTitleLine() {
        let app = launchInstructions([]); defer { app.terminate() }
        expand(app, title: AgentInstructions.title)
        let theme = ink(app, navigationTitle(app, AgentInstructions.title))
        for (id, summary) in AgentInstructions.summaries {
            let row = app.buttons["agent-instructions-section-\(id)"]
            XCTAssertTrue(row.isHittable, "\(id)\n\(app.debugDescription)")
            XCTAssertTrue(row.label.contains(summary), "\(id) shows its summary: \(row.label)")
            // The list standard (#1691) puts the summary under the title, as subtext.
            assertInk(ink(app, row, leading: 56), theme, "\(id) number")
        }
        XCTAssertTrue(app.buttons["agent-instructions-section-tron"].label.contains("Each turn"))
        app.terminate()

        let large = launchInstructions(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        defer { large.terminate() }
        let window = large.windows.firstMatch.frame
        for (id, summary) in AgentInstructions.summaries {
            let row = large.buttons["agent-instructions-section-\(id)"]
            for _ in 0..<6 where !row.isHittable { large.swipeUp() }
            XCTAssertTrue(row.label.contains(summary), "\(id) at XXXL: \(row.label)")
            XCTAssertLessThanOrEqual(row.frame.maxX, window.maxX, "\(id) stays within the screen at XXXL")
            XCTAssertGreaterThan(row.frame.height, 56, "\(id)'s summary moves below its title at XXXL")
        }
    }

    private enum AgentInstructions {
        static let title = "Instructions"
        static let summaries = [("preamble", "Built into Pi"), ("tools", "3 tools"), ("rules", "3 rules · 1 from tools"),
                                ("cwd", "~/Workspace/project")]
    }

    // MARK: Journeys

    @MainActor private func launchManageSession(dark: Bool) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-configuration-fixture", "-settings-scope-review", "-manage-session-review",
                               "-fixture-appearance", dark ? "dark" : "light"]
        app.launch()
        XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 10))
        app.buttons["Stop session"].tap()
        XCTAssertTrue(element(app, "session-usage-summary").waitForExistence(timeout: 10), app.debugDescription)
        expand(app, title: "Manage Session")
        return app
    }

    @MainActor private func launchManageHome(dark: Bool) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"] + (dark ? ["-home-dark"] : [])
        app.launch()
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 15))
        app.buttons["home-pinned-row"].tap()
        let ring = app.buttons["session-context-button"]
        XCTAssertTrue(waitFor(ring, "enabled == true"))
        ring.tap()
        XCTAssertTrue(element(app, "home-manage-state").waitForExistence(timeout: 8), app.debugDescription)
        expand(app, done: "home-sheet-done-manage")
        Thread.sleep(forTimeInterval: 0.6)
        return app
    }

    @MainActor private func launchInstructions(_ arguments: [String]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-agent-instructions-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["agent-instructions-section-preamble"].waitForExistence(timeout: 10), app.debugDescription)
        return app
    }

    /// Taps a Manage Session row by its label and waits for its sheet to settle large.
    @MainActor private func open(_ app: XCUIApplication, row label: String) {
        let row = app.buttons[label].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), app.debugDescription)
        for _ in 0..<6 where !row.isHittable { app.swipeUp() }
        row.tap()
        Thread.sleep(forTimeInterval: 1.0)
        let title = app.navigationBars.staticTexts.allElementsBoundByIndex.last?.label ?? label
        expand(app, title: title)
        Thread.sleep(forTimeInterval: 1.0)
    }

    // MARK: Helpers

    @MainActor private func navigationTitle(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        let titles = app.navigationBars.descendants(matching: .any).matching(NSPredicate(format: "label == %@", text))
        return titles.allElementsBoundByIndex.last ?? titles.firstMatch
    }

    /// The average saturated ink of `element` (its leading icon column when given).
    @MainActor private func ink(_ app: XCUIApplication, _ element: XCUIElement, leading: CGFloat? = nil) -> [Double] {
        XCTAssertTrue(element.waitForExistence(timeout: 5), app.debugDescription)
        Thread.sleep(forTimeInterval: 0.4)
        var area = element.frame
        if let leading { area.size.width = leading }
        guard let ink = sheetInk(XCUIScreen.main.screenshot().image, area, window: app.windows.firstMatch.frame.width) else {
            XCTFail("No inked pixels in \(element)"); return [0, 0, 0]
        }
        return ink
    }

    /// Compares hue, not brightness: a thin glyph's antialiasing darkens its ink
    /// toward the background, so each color is scaled to its brightest channel.
    /// Emerald and the retired teal differ by about 0.3 on this scale.
    private func assertInk(_ ink: [Double], _ theme: [Double], _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let hue = { (color: [Double]) in color.map { $0 / max(color.max() ?? 1, 0.01) } }
        let distance = zip(hue(ink), hue(theme)).map { abs($0 - $1) }.max() ?? 1
        XCTAssertLessThan(distance, 0.15, "\(what) \(ink) is not the sheet theme \(theme)", file: file, line: line)
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Brings the sheet titled `text` to its large detent once it stops presenting.
    @MainActor private func expand(_ app: XCUIApplication, title text: String) {
        let title = app.navigationBars.staticTexts.matching(NSPredicate(format: "label == %@", text)).allElementsBoundByIndex.last
            ?? app.staticTexts[text].firstMatch
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

    @MainActor private func expand(_ app: XCUIApplication, done id: String) {
        let done = app.buttons[id].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 8), id)
        guard done.frame.minY > 120 else { return }
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: 60, dy: done.frame.midY))
            .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: 60, dy: 20)))
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "frame.minY < 120"), object: done)], timeout: 3)
    }

    @MainActor private func closeTop(_ app: XCUIApplication) {
        let done = app.buttons.matching(NSPredicate(format: "label == 'Done'")).allElementsBoundByIndex.last(where: \.isHittable)
        XCTAssertNotNil(done, app.debugDescription)
        done?.tap()
        Thread.sleep(forTimeInterval: 0.8)
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
