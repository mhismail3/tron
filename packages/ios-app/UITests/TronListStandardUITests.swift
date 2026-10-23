import XCTest

/// The shared list standard (#1691) across the eight Manage Home and Manage
/// Session list sheets, driven through their real fixtures.
final class TronListStandardUITests: XCTestCase {
    @MainActor func testCaptureHomeSheetsLight() { captureHome(dark: false) }
    @MainActor func testCaptureHomeSheetsDark() { captureHome(dark: true) }
    @MainActor func testCaptureSessionSheetsLight() { captureSession(dark: false) }
    @MainActor func testCaptureSessionSheetsDark() { captureSession(dark: true) }
    @MainActor func testCaptureInstructionsAndSubagents() {
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            let app = XCUIApplication()
            app.launchArguments = ["-tron-agent-instructions-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + (dark ? ["-home-dark"] : [])
            app.launch()
            XCTAssertTrue(element(app, "agent-instructions-section-preamble").waitForExistence(timeout: 10), app.debugDescription)
            expandSheet(app, title: "Instructions")
            shot("instructions-\(mode)")
            app.terminate()
            app.launchArguments = ["-tron-subagent-parity-fixture", "-history-grouping", dark ? "-dark" : "-light"]
            app.launch()
            let open = app.buttons["Subagent History"]
            XCTAssertTrue(open.waitForExistence(timeout: 10), app.debugDescription)
            open.tap()
            XCTAssertTrue(app.buttons["subagent-row-worker"].waitForExistence(timeout: 5), app.debugDescription)
            expandSheet(app, title: "Subagent History")
            shot("subagent-history-\(mode)")
            app.terminate()
        }
    }

    /// The Instructions overview and its Tools, Rules and Skills subsheets, light and
    /// dark at standard text and at XXXL.
    @MainActor func testCaptureInstructionRows() {
        for (mode, extra) in [("light", [String]()), ("dark", ["-home-dark"]),
                              ("xxxl", ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"])] {
            for section in ["tools", "rules", "skills"] {
                let app = XCUIApplication()
                app.launchArguments = ["-tron-agent-instructions-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extra
                app.launch()
                XCTAssertTrue(element(app, "agent-instructions-section-preamble").waitForExistence(timeout: 10), app.debugDescription)
                expandSheet(app, title: "Instructions")
                if section == "tools" { shot("instructions-\(mode)") }
                let row = app.buttons["agent-instructions-section-\(section)"]
                for _ in 0..<4 where !row.isHittable { app.swipeUp() }
                row.tap()
                let title = ["tools": "Tools", "rules": "Rules", "skills": "Skills"][section]!
                expandSheet(app, title: title)
                let entry = element(app, "agent-instructions-entry-\(section).0")
                for _ in 0..<4 where !entry.isHittable { app.swipeUp() }
                Thread.sleep(forTimeInterval: 0.6)
                shot("\(section)-\(mode)")
                app.terminate()
            }
        }
    }

    @MainActor private func captureHome(dark: Bool) {
        continueAfterFailure = false
        let mode = dark ? "dark" : "light"
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-paging"] + (dark ? ["-home-dark"] : [])
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        let ring = app.buttons["session-context-button"]
        XCTAssertTrue(waitFor(ring, "enabled == true"))
        ring.tap()
        XCTAssertTrue(element(app, "home-manage-state").waitForExistence(timeout: 10), app.debugDescription)
        expandSheet(app, title: "Manage Home")
        for (row, title, done, name) in [("home-manage-profile", "Profile", "home-sheet-done-profile", "profile"),
                                         ("home-manage-chapters", "Chapters", "home-sheet-done-chapters", "chapters")] {
            let open = element(app, row)
            for _ in 0..<6 where !open.isHittable { app.swipeUp() }
            open.tap()
            expandSheet(app, title: title)
            Thread.sleep(forTimeInterval: 1)
            shot("\(name)-\(mode)")
            app.buttons[done].tap()
            Thread.sleep(forTimeInterval: 0.8)
        }
        let memory = element(app, "home-manage-memory-browser")
        for _ in 0..<6 where !memory.isHittable { app.swipeUp() }
        memory.tap()
        expandSheet(app, title: "Memory")
        Thread.sleep(forTimeInterval: 1)
        shot("memory-top-\(mode)")
        for _ in 0..<2 { app.swipeUp() }
        Thread.sleep(forTimeInterval: 1)
        shot("memory-scrolled-\(mode)")
        app.buttons["home-sheet-done-memory"].tap()
        Thread.sleep(forTimeInterval: 0.8)
        let tasks = element(app, "home-manage-tasks")
        for _ in 0..<6 where !tasks.isHittable { app.swipeUp() }
        tasks.tap()
        expandSheet(app, title: "Tasks")
        Thread.sleep(forTimeInterval: 1)
        shot("tasks-top-\(mode)")
        for _ in 0..<4 { app.swipeUp() }
        // The fixture refuses the first older page once: the feed keeps its rows and offers Retry.
        if element(app, "feed-retry").waitForExistence(timeout: 5) {
            shot("tasks-error-\(mode)")
            element(app, "feed-retry").tap()
        }
        for _ in 0..<8 { app.swipeUp() }
        Thread.sleep(forTimeInterval: 1)
        shot("tasks-end-\(mode)")
    }

    @MainActor private func captureSession(dark: Bool) {
        continueAfterFailure = false
        let mode = dark ? "dark" : "light"
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-configuration-fixture", "-manage-session-review", "-history-large",
                               "-fixture-appearance", mode]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 10))
        app.buttons["Stop session"].tap()
        let history = app.buttons["Session History"]
        for _ in 0..<12 where !history.isHittable { app.swipeUp() }
        history.tap()
        XCTAssertTrue(element(app, "history-row-h-6732").waitForExistence(timeout: 10), app.debugDescription)
        expandSheet(app, title: "Session History")
        Thread.sleep(forTimeInterval: 1)
        shot("history-top-\(mode)")
        for _ in 0..<5 { app.swipeUp(velocity: .fast) }
        Thread.sleep(forTimeInterval: 0.3)
        shot("history-scrolled-\(mode)")
        Thread.sleep(forTimeInterval: 1.5)
        let chip = element(app, "feed-position-chip")
        XCTAssertTrue(chip.waitForExistence(timeout: 5), app.debugDescription)
        chip.tap()
        Thread.sleep(forTimeInterval: 1)
        let row = element(app, "history-row-h-6731")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.press(forDuration: 1.0)
        Thread.sleep(forTimeInterval: 1)
        shot("history-menu-\(mode)")
        XCTAssertTrue(app.buttons["Fork New Session"].exists, app.debugDescription)
        // Dismiss the menu without choosing an action.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        Thread.sleep(forTimeInterval: 1)
        row.tap()
        XCTAssertTrue(element(app, "history-entry-actions").waitForExistence(timeout: 8), app.debugDescription)
        expandSheet(app, title: "History Entry")
        Thread.sleep(forTimeInterval: 1)
        shot("history-detail-\(mode)")
        app.navigationBars.containing(.staticText, identifier: "History Entry").buttons["Done"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1)
        app.navigationBars.containing(.staticText, identifier: "Session History").buttons["Done"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1)
        let resources = app.buttons.matching(NSPredicate(format: "label IN {'Resources', 'Project Resources'}")).firstMatch
        for _ in 0..<8 where !resources.isHittable { app.swipeUp() }
        resources.tap()
        XCTAssertTrue(app.buttons["project-resource-skills-0"].waitForExistence(timeout: 10), app.debugDescription)
        expandSheet(app, title: "Resources")
        Thread.sleep(forTimeInterval: 1)
        shot("resources-\(mode)")
        app.swipeUp()
        Thread.sleep(forTimeInterval: 1)
        shot("resources-bottom-\(mode)")
    }

    // MARK: Behaviour

    /// A feed row's anatomy on the real Session History fixture: the kind icon is
    /// centred on the row, the one status pill sits top-right, and actions come
    /// from the detail and an identical long-press menu, never a ⋯ button.
    @MainActor func testFeedRowAnatomyAndActions() {
        let app = openLargeHistory()
        let row = app.buttons["history-row-h-6732"]
        let leading = element(app, "history-row-h-6732-leading")
        let status = element(app, "history-row-h-6732-status")
        XCTAssertTrue(leading.waitForExistence(timeout: 5), "The row publishes its leading slot\n\(app.debugDescription)")
        XCTAssertTrue(status.exists, "The current entry carries one status pill")
        XCTAssertEqual(leading.frame.midY, row.frame.midY, accuracy: 2, "The leading icon is centred vertically in the row")
        XCTAssertLessThan(leading.frame.maxX, row.frame.minX + 50, "The leading slot is on the left")
        XCTAssertGreaterThan(status.frame.maxX, row.frame.maxX - 24, "The status pill is at the trailing edge")
        XCTAssertLessThan(status.frame.minY - row.frame.minY, 20, "The status pill is on the first line")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Actions for'")).count, 0, "Rows have no ⋯ menu")
        XCTAssertFalse(app.images["ellipsis"].exists, "Rows have no ⋯ menu")
        let menuActions = ["Continue From Here", "Fork New Session", "Edit Bookmark", "Copy Text"]
        let bookmarked = app.buttons["history-row-h-6731"]
        bookmarked.press(forDuration: 1.0)
        for action in menuActions {
            XCTAssertTrue(app.buttons[action].waitForExistence(timeout: 5), "Long-press offers \(action)\n\(app.debugDescription)")
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        _ = waitFor(app.buttons["Copy Text"], "exists == false", timeout: 5)
        bookmarked.tap()
        XCTAssertTrue(element(app, "history-entry-actions").waitForExistence(timeout: 8), app.debugDescription)
        for (id, title) in zip(["navigate", "fork", "bookmark", "copy"], menuActions) {
            let action = app.buttons["history-entry-action-\(id)"]
            XCTAssertTrue(action.exists, "The detail holds \(title)")
            XCTAssertTrue(action.label.hasPrefix(title), "The detail names \(title): \(action.label)")
        }
    }

    /// The feed pages itself while the reader scrolls (no Older/Newer buttons),
    /// the pinned chip names the visible range of the whole feed, and tapping the
    /// chip returns to the newest entry.
    @MainActor func testFeedAutoLoadsAndChipJumpsToNewest() {
        let app = openLargeHistory()
        XCTAssertFalse(app.buttons["history-older-top"].exists, "No explicit paging control")
        let secondPage = app.buttons["history-row-h-6630"]
        var swipes = 0
        while !secondPage.exists && swipes < 40 { app.swipeUp(velocity: .fast); swipes += 1 }
        XCTAssertTrue(secondPage.exists, "Scrolling alone loads the next page")
        XCTAssertEqual(app.buttons.matching(identifier: "history-row-h-6632").count, 1, "Pages never duplicate rows")
        let chip = app.buttons["feed-position-chip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "A long feed shows its position chip")
        XCTAssertTrue(chip.label.contains("of 6,733"), "The chip counts the whole feed: \(chip.label)")
        XCTAssertFalse(app.buttons["history-row-h-6732"].isHittable)
        chip.tap()
        XCTAssertTrue(waitFor(app.buttons["history-row-h-6732"], "hittable == true", timeout: 5), "The chip jumps to the newest entry")
    }

    /// Grouped lists: a status row's pill is top-right, ordinal rows centre their
    /// number, and rows without kind carry no leading icon.
    @MainActor func testGroupedRowAnatomy() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-agent-instructions-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); defer { app.terminate() }
        let row = app.buttons["agent-instructions-section-preamble"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        let ordinal = element(app, "agent-instructions-section-preamble-leading")
        XCTAssertTrue(ordinal.waitForExistence(timeout: 5), "Instructions keep their reading-order number\n\(app.debugDescription)")
        XCTAssertEqual(ordinal.frame.midY, row.frame.midY, accuracy: 2, "The number is centred vertically in the row")
        app.terminate()

        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
        app.launch()
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        let ring = app.buttons["session-context-button"]
        XCTAssertTrue(waitFor(ring, "enabled == true"))
        ring.tap()
        let chapters = element(app, "home-manage-chapters")
        XCTAssertTrue(chapters.waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<6 where !chapters.isHittable { app.swipeUp() }
        chapters.tap()
        let chapter = app.buttons["home-chapter-1"]
        XCTAssertTrue(chapter.waitForExistence(timeout: 10), app.debugDescription)
        let pill = element(app, "home-chapter-1-status")
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "A chapter carries its state as one pill")
        XCTAssertGreaterThan(pill.frame.maxX, chapter.frame.maxX - 24, "The pill is at the trailing edge")
        XCTAssertLessThan(pill.frame.minY - chapter.frame.minY, 20, "The pill is on the title line")
        XCTAssertFalse(element(app, "home-chapter-1-leading").exists, "Chapters carry no repeated icon")
    }

    /// Stacked groups (#1700): every titled section of a grouped list is its own
    /// container, apart from the next, with its header and count above it on the
    /// container's edges, on both sheets that stack groups (Profile, Resources).
    @MainActor func testGroupedSectionsAreSeparateContainersWithHeadersAbove() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        let ring = app.buttons["session-context-button"]
        XCTAssertTrue(waitFor(ring, "enabled == true"))
        ring.tap()
        let profile = element(app, "home-manage-profile")
        XCTAssertTrue(profile.waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<6 where !profile.isHittable { app.swipeUp() }
        profile.tap()
        expandSheet(app, title: "Profile")
        assertSeparateSections(app, list: "home-profile-items", titles: ["Preferences", "Standing decisions"],
                               row: "home-profile-item-9a364c45-34fe-4f0a-93e6-fc507e2b0bdc")
        app.terminate()

        app.launchArguments = ["-tron-session-configuration-fixture", "-manage-session-review", "-fixture-appearance", "light"]
        app.launch()
        XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 10))
        app.buttons["Stop session"].tap()
        let resources = app.buttons.matching(NSPredicate(format: "label IN {'Resources', 'Project Resources'}")).firstMatch
        for _ in 0..<8 where !resources.isHittable { app.swipeUp() }
        resources.tap()
        XCTAssertTrue(app.buttons["project-resource-skills-0"].waitForExistence(timeout: 10), app.debugDescription)
        expandSheet(app, title: "Resources")
        assertSeparateSections(app, list: "project-resource-groups", titles: ["Skills", "Subagents"], row: "project-resource-skills-0")
    }

    @MainActor private func assertSeparateSections(_ app: XCUIApplication, list: String, titles: [String], row: String) {
        var previousBottom: CGFloat?
        for (index, title) in titles.enumerated() {
            let header = element(app, "\(list)-header-\(index)"), section = element(app, "\(list)-section-\(index)")
            XCTAssertTrue(header.waitForExistence(timeout: 5) && section.exists, "\(list) section \(index) has its own header and container\n\(app.debugDescription)")
            XCTAssertTrue(header.label.hasPrefix(title) && header.label.rangeOfCharacter(from: .decimalDigits) != nil,
                          "The header names \(title) and its count: \(header.label)")
            XCTAssertLessThanOrEqual(header.frame.maxY, section.frame.minY + 0.5, "\(title)'s header sits above its container")
            XCTAssertEqual(header.frame.minX, section.frame.minX, accuracy: 1, "\(title)'s header starts on the container's leading edge")
            XCTAssertEqual(header.frame.maxX, section.frame.maxX, accuracy: 1, "\(title)'s count ends on the container's trailing edge")
            if let previousBottom {
                XCTAssertGreaterThan(header.frame.minY - previousBottom, 8, "\(title) starts apart from the previous container")
            }
            previousBottom = section.frame.maxY
        }
        let first = element(app, "\(list)-section-0"), firstRow = app.buttons[row]
        XCTAssertTrue(first.frame.contains(firstRow.frame.insetBy(dx: 1, dy: 1)), "The first row is inside the first container")
    }

    /// Tasks page themselves; a refused page keeps the rows and offers Retry, and
    /// the feed ends with an explicit end row.
    @MainActor func testTaskFeedRetriesAndEnds() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-paging"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        let ring = app.buttons["session-context-button"]
        XCTAssertTrue(waitFor(ring, "enabled == true"))
        ring.tap()
        let tasks = element(app, "home-manage-tasks")
        XCTAssertTrue(tasks.waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<6 where !tasks.isHittable { app.swipeUp() }
        tasks.tap()
        XCTAssertTrue(app.buttons["home-task-active"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["home-tasks-older-top"].exists, "No explicit paging control")
        let retry = app.buttons["feed-retry"]
        for _ in 0..<10 where !retry.exists { app.swipeUp(velocity: .fast) }
        XCTAssertTrue(retry.waitForExistence(timeout: 5), "A refused page offers Retry in the feed\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["home-task-paged-19"].exists, "A failed page keeps the loaded rows")
        retry.tap()
        let end = element(app, "feed-end")
        for _ in 0..<12 where !end.exists { app.swipeUp(velocity: .fast) }
        XCTAssertTrue(end.waitForExistence(timeout: 5), "The feed ends with an end row")
        XCTAssertEqual(app.buttons.matching(identifier: "home-task-paged-44").count, 1)
    }

    /// Scrolling a loaded feed back up settles: the lazy feed must reach idle after
    /// every swipe (a pinned chip once re-placed rows without end).
    @MainActor func testLoadedFeedSettlesWhileScrollingBackUp() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-paging", "-home-browser-paging"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        let ring = app.buttons["session-context-button"]
        XCTAssertTrue(waitFor(ring, "enabled == true"))
        ring.tap()
        let memory = element(app, "home-manage-memory-browser")
        XCTAssertTrue(memory.waitForExistence(timeout: 10), app.debugDescription)
        // At its large detent Manage Home shows Memory without a scroll whose momentum can eat the tap (#1699).
        expandSheet(app, title: "Manage Home")
        memory.tap()
        XCTAssertTrue(app.buttons["home-memory-row-39"].waitForExistence(timeout: 10), app.debugDescription)
        expandSheet(app, title: "Memory")
        let retry = app.buttons["feed-retry"]
        for _ in 0..<8 where !retry.exists { app.swipeUp() }
        if retry.waitForExistence(timeout: 5) { retry.tap() }
        XCTAssertTrue(app.buttons["home-memory-summary-0-16"].waitForExistence(timeout: 5))
        for round in 0..<4 {
            for _ in 0..<4 {
                let started = Date()
                round % 2 == 0 ? app.swipeDown() : app.swipeUp()
                XCTAssertLessThan(Date().timeIntervalSince(started), 15, "The feed settles after each swipe (round \(round))")
            }
        }
    }

    @MainActor private func openLargeHistory() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-configuration-fixture", "-history-large", "-fixture-appearance", "light"]
        app.launch()
        addTeardownBlock { app.terminate() }
        XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 10))
        app.buttons["Stop session"].tap()
        let history = app.buttons["Session History"]
        for _ in 0..<12 where !history.isHittable { app.swipeUp() }
        history.tap()
        XCTAssertTrue(app.buttons["history-row-h-6732"].waitForExistence(timeout: 10), app.debugDescription)
        expandSheet(app, title: "Session History")
        return app
    }

    // MARK: Helpers

    @MainActor private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func waitFor(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 10) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)], timeout: timeout) == .completed
    }

    /// Brings a sheet to its large detent by dragging its title toward the top.
    @MainActor private func expandSheet(_ app: XCUIApplication, title text: String) {
        let title = app.navigationBars.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 8), app.debugDescription)
        var last = title.frame.minY
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.3)
            let now = title.frame.minY
            if abs(now - last) < 0.5 { break }
            last = now
        }
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        for _ in 0..<4 where title.frame.minY > 120 {
            origin.withOffset(CGVector(dx: 60, dy: title.frame.midY))
                .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: 60, dy: 20)))
            Thread.sleep(forTimeInterval: 0.6)
        }
    }
}
