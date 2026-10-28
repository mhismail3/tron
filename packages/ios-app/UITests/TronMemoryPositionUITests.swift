import XCTest

/// Real Home sheets and RPC fixture: catalog addresses, message counts and
/// summary positions deliberately differ. Captures are simulator review proof.
@MainActor final class TronMemoryPositionUITests: XCTestCase {
    func testScopedMemoryLight() throws { try journey(dark: false, large: false) }
    func testScopedMemoryDark() throws { try journey(dark: true, large: false) }
    func testScopedMemoryAccessibility() throws { try journey(dark: false, large: true) }
    /// Memory stays at the detent users first see; iOS draws that sheet scaled.
    func testMediumMemoryLight() throws { try journey(dark: false, large: false, expandsMemory: false) }
    func testMediumMemoryDark() throws { try journey(dark: true, large: false, expandsMemory: false) }

    func testPagedMemoryAndTasksLabelLoadedItems() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-paging", "-home-browser-paging"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        XCTAssertTrue(app.buttons["session-context-button"].waitForExistence(timeout: 10))
        app.buttons["session-context-button"].tap()
        try expand(app, "Manage Home")
        for (row, title, viewport, done) in [
            ("home-manage-memory-browser", "Memory", "home-memory-viewport", "home-sheet-done-memory"),
            ("home-manage-tasks", "Tasks", "home-tasks-viewport", "home-sheet-done-tasks")
        ] {
            try reveal(app, row).tap()
            try expand(app, title)
            element(app, viewport).swipeUp()
            let chip = app.buttons["feed-position-chip"]
            XCTAssertTrue(chip.waitForExistence(timeout: 10))
            XCTAssertTrue(chip.label.hasPrefix("Items "), chip.label)
            if title == "Memory" {
                // The fixture refuses its second page. A lower bound cannot be
                // announced as the exact size of the whole memory.
                XCTAssertTrue(chip.label.contains("of at least 10"), chip.label)
            }
            shot("paged-\(title.lowercased())")
            app.buttons[done].tap()
        }
    }

    private func journey(dark: Bool, large: Bool, expandsMemory: Bool = true) throws {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-memory-position-regression",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            + (dark ? ["-home-dark"] : [])
            + (large ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : [])
        app.launch(); defer { app.terminate() }
        let mode = (expandsMemory ? "" : "medium-") + (large ? "accessibility" : dark ? "dark" : "light")
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        let ring = app.buttons["session-context-button"]
        XCTAssertTrue(ring.waitForExistence(timeout: 10)); ring.tap()
        try expand(app, "Manage Home", required: !large)
        try reveal(app, "home-manage-chapters").tap()
        XCTAssertTrue(app.buttons["home-chapter-1"].waitForExistence(timeout: 10))
        try expand(app, "Chapters", required: !large)
        shot("chapters-list-\(mode)")
        app.buttons["home-chapter-1"].tap()
        XCTAssertTrue(element(app, "home-chapter-detail").waitForExistence(timeout: 10))
        try expand(app, "Chapters", required: !large)
        let browse = try reveal(app, "home-chapter-browse-memory")
        shot("chapters-header-\(mode)")
        XCTAssertFalse(app.staticTexts["From Home's summaries of this chapter."].exists,
                       "Topics already names the chapter summaries; no redundant caption can scroll behind Chapters")
        browse.tap()
        XCTAssertTrue(app.buttons["home-memory-summary-7672-8"].waitForExistence(timeout: 10))
        if expandsMemory { try expand(app, "Memory", required: !large) }
        checkChip(app, count: 32, mode: "scoped-\(mode)")
        app.buttons["home-sheet-done-memory"].tap()
        app.buttons["home-sheet-done-chapter"].tap()
        app.buttons["home-sheet-done-chapters"].tap()
        try reveal(app, "home-manage-memory-browser").tap()
        XCTAssertTrue(app.buttons["home-memory-summary-7736-8"].waitForExistence(timeout: 10))
        if expandsMemory { try expand(app, "Memory", required: !large) }
        checkChip(app, count: 40, mode: "unscoped-\(mode)")
    }

    private func checkChip(_ app: XCUIApplication, count: Int, mode: String) {
        let chip = app.buttons["feed-position-chip"]
        // Visibility publishes the scrolling range, not merely sheet expansion.
        element(app, "home-memory-viewport").swipeUp()
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        shot("memory-pill-\(mode)")
        // Assert semantics, not a particular number of visible rows or font layout.
        let label = chip.label
        let numbers = label.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init)
        XCTAssertTrue(label.hasPrefix("Items "), label)
        XCTAssertEqual(numbers.count, 3, label)
        if numbers.count == 3 {
            XCTAssertEqual(numbers[2], count, "Total counts this list's rows, never catalog messages")
            XCTAssertTrue((1...count).contains(numbers[0]) && (numbers[0]...count).contains(numbers[1]), label)
        }
        XCTContext.runActivity(named: "Chip \(mode): frame=\(chip.frame)") { _ in }
        XCTAssertGreaterThanOrEqual(chip.frame.height, 44)
        XCTAssertLessThanOrEqual(chip.frame.width, app.windows.firstMatch.frame.width - 32)
        chip.tap()
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private enum NavigationFailure: Error { case unavailable(String) }

    private func navigationFailure(_ message: String) -> NavigationFailure {
        XCTFail(message)
        return .unavailable(message)
    }

    /// The presented sheet is the last navigation bar. Several sheets share a
    /// title (Chapters list/detail), so a title query alone can name a covered
    /// parent; wait until the frontmost bar itself is settled and, if given, titled.
    private func frontmostBar(_ app: XCUIApplication, titled title: String? = nil) throws -> XCUIElement {
        let deadline = Date().addingTimeInterval(10)
        var lastFrame = CGRect.null
        repeat {
            if let bar = app.navigationBars.allElementsBoundByIndex.last, bar.exists,
               title.map({ bar.staticTexts[$0].exists }) ?? true {
                if bar.frame == lastFrame { return bar }
                lastFrame = bar.frame
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        } while Date() < deadline
        throw navigationFailure("Frontmost sheet\(title.map { " '\($0)'" } ?? "") never settled: \(app.navigationBars.allElementsBoundByIndex.map(\.frame))")
    }

    /// Waits for an element's frame to stop changing, so a measurement never mixes
    /// a presentation mid-transition with the one it settles into.
    private func settle(_ element: XCUIElement) throws {
        var last = CGRect.null
        for _ in 0..<20 {
            if element.exists, element.frame == last { return }
            last = element.frame
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        throw navigationFailure("\(element.identifier) never settled: \(element.frame)")
    }

    private func reveal(_ app: XCUIApplication, _ id: String) throws -> XCUIElement {
        let target = element(app, id)
        XCTAssertTrue(target.waitForExistence(timeout: 10), app.debugDescription)
        guard target.exists else { throw navigationFailure("Cannot reveal missing row \(id)") }
        var usable: CGRect?
        for _ in 0..<12 {
            // AX can report a row under the toolbar as hittable. Require its
            // frame (and hence tap point) to clear both sheet edges before tap.
            // Bind to the one presentation that owns the target: its own scroll
            // view, and the bar inside that scroll. Taking whichever bar is last
            // can flip between a covered medium parent and a large child.
            try settle(target)
            guard let scroll = app.scrollViews.containing(.any, identifier: id).allElementsBoundByIndex
                    .last(where: { $0.frame.height > 150 && $0.isHittable }) else {
                throw navigationFailure("Cannot find the scroll view owning \(id)")
            }
            guard let bar = app.navigationBars.allElementsBoundByIndex.last(where: {
                scroll.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
            }) else {
                throw navigationFailure("Cannot find the toolbar inside the scroll owning \(id): scroll=\(scroll.frame)")
            }
            let window = app.windows.firstMatch
            let visible = scroll.frame.intersection(window.frame)
            let top = max(visible.minY, bar.frame.maxY) + 12
            let bottom = min(visible.maxY, window.frame.maxY - 34) - 12
            guard bottom > top, visible.width > 24 else {
                throw navigationFailure("No usable scroll content for \(id): scroll=\(visible), toolbar=\(bar.frame)")
            }
            let content = CGRect(x: visible.minX + 12, y: top, width: visible.width - 24, height: bottom - top)
            usable = content
            let row = target.frame
            XCTContext.runActivity(named: "Reveal \(id): row=\(row), sheet=\(visible), toolbar=\(bar.frame), usable=\(content)") { _ in }
            if content.contains(row), target.isHittable { break }
            // A held, measured drag centres the row without a fling carrying
            // it past the opposite edge between observation and tap.
            let middle = content.midY
            // Up to the usable height per drag, so a tall large-type page needs few
            // steps within the unchanged 12-step bound.
            let step = content.height * 0.9
            let delta = max(-step, min(step, middle - row.midY))
            let origin = window.coordinate(withNormalizedOffset: .zero)
            // Start in the content's side gutter: a drag begun on a Menu/Button row
            // can be claimed by that control instead of scrolling (seen at large type).
            let start = origin.withOffset(CGVector(dx: visible.minX + 8, dy: middle - delta / 2))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: delta)),
                        withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTAssertTrue(target.isHittable, app.debugDescription)
        guard let usable, usable.contains(target.frame), target.isHittable else {
            throw navigationFailure("Row \(id) is not clear for tapping after 12 steps: row=\(target.frame), usable=\(String(describing: usable))")
        }
        return target
    }
    /// `required` is false at the largest text size, where every sheet settled back
    /// after every drag (measured for Manage Home with title, sheet-edge, beside-title
    /// and x=60 origins; Memory with the title). Its rows stay reachable by the measured
    /// scroll in `reveal`, and the chip is then measured at the detent the sheet holds.
    private func expand(_ app: XCUIApplication, _ title: String, required: Bool = true) throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(try frontmostBar(app, titled: title).staticTexts[title].firstMatch.waitForExistence(timeout: 10))
        // Drag the frontmost sheet's own measured title at default velocity, as
        // the shared sheet tests do (a slow drag only nudges the sheet at large
        // type and it settles back); never the first same-titled heading of a covered parent.
        for _ in 0..<4 {
            let bar = try frontmostBar(app, titled: title)
            if bar.frame.minY <= 120 { return }
            let heading = bar.staticTexts[title].firstMatch
            XCTContext.runActivity(named: "Expand '\(title)': heading=\(heading.frame), toolbar=\(bar.frame)") { _ in }
            heading.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)))
        }
        let bar = try frontmostBar(app, titled: title)
        if !required { return }
        guard bar.frame.minY <= 120 else {
            throw navigationFailure("Sheet '\(title)' did not reach its large detent after 4 title drags: toolbar=\(bar.frame)")
        }
    }
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
