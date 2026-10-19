import XCTest

/// Manage Home and every sub-sheet, walked end to end on the hosted Home fixture
/// (#911). The journey proves the sheet structure, the memory hierarchy Home sees,
/// the removed task controls, and that returning to a loaded sheet reads nothing
/// again. Each step keeps a large-detent screenshot, and the open timings and read
/// counts are kept as a JSON attachment (`home-sheet-measurements`).
final class TronHomeSheetsUITests: XCTestCase {
    private var timings: [String: Double] = [:]

    @MainActor
    func testHostPressureNormalAndIdleWorkers() {
        checkHostStatus(level: "Normal", workers: "0 workers running", arguments: [])
    }

    @MainActor
    func testHostPressureElevatedAndSingleWorkerInDarkMode() {
        checkHostStatus(level: "Elevated", workers: "1 worker running",
                        arguments: ["-host-elevated", "-home-dark"])
    }

    @MainActor
    func testHostPressureCriticalAndUncappedWorkersAtLargeText() {
        checkHostStatus(level: "Critical", workers: "7 workers running",
                        arguments: ["-host-critical", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
    }

    @MainActor
    private func checkHostStatus(level: String, workers: String, arguments: [String]) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"] + arguments
        app.launch(); defer { app.terminate() }
        let home = app.buttons["home-pinned-row"]
        XCTAssertTrue(home.waitForExistence(timeout: 15))
        XCTAssertTrue(home.label.contains("Host \(level.lowercased())"), home.label)
        XCTAssertTrue(home.label.contains(workers), home.label)
        let dashboard = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        dashboard.name = "931-\(level)-dashboard"
        dashboard.lifetime = .keepAlways
        add(dashboard)
        home.tap()
        let ring = app.buttons["session-context-button"]
        XCTAssertTrue(ring.waitForExistence(timeout: 15))
        XCTAssertTrue(waitFor(ring, "enabled == true"))
        open(app, ring, ready: "home-manage-state", name: "host-status")
        expand(app, done: "home-sheet-done-manage")
        let host = element(app, "home-manage-host")
        // Hittable alone can mean only the title is visible at accessibility
        // sizes. Bring the whole row, including the status pill, above the edge.
        for _ in 0..<8 where !host.isHittable || host.frame.maxY > app.frame.maxY - 60 { app.swipeUp() }
        XCTAssertTrue(host.isHittable, app.debugDescription)
        XCTAssertLessThanOrEqual(host.frame.maxY, app.frame.maxY - 60, "The complete host status remains visible")
        XCTAssertTrue(host.label.contains(workers), host.label)
        XCTAssertTrue(host.label.contains(level), host.label)
        XCTAssertFalse(host.label.lowercased().contains("queued"), "Home workers have no queue")
        let memory = element(app, "home-manage-memory-browser")
        if memory.isHittable {
            XCTAssertEqual(host.frame.minX, memory.frame.minX, accuracy: 1, "Host uses the shared row alignment")
            XCTAssertEqual(host.frame.width, memory.frame.width, accuracy: 1, "Host uses the shared row width")
        }
        XCTAssertGreaterThanOrEqual(host.frame.minX, 0)
        XCTAssertLessThanOrEqual(host.frame.maxX, app.frame.maxX)
        keep("931-\(level)-manage")
    }

    /// Home Settings stacks its cards with one shared gap and no section header
    /// above the inline Tools card (#1478), in light, dark and accessibility text.
    @MainActor func testHomeSettingsCardsLight() { homeSettingsCards(name: "light", arguments: []) }
    @MainActor func testHomeSettingsCardsDark() { homeSettingsCards(name: "dark", arguments: ["-home-dark"]) }
    @MainActor func testHomeSettingsCardsAccessibilityText() {
        homeSettingsCards(name: "ax-large", arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
    }

    @MainActor private func homeSettingsCards(name: String, arguments: [String]) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"] + arguments
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 15))
        app.buttons["home-pinned-row"].tap()
        let ring = app.buttons["session-context-button"]
        XCTAssertTrue(waitFor(ring, "enabled == true"))
        open(app, ring, ready: "home-manage-state", name: "manage")
        expand(app, done: "home-sheet-done-manage")
        let row = element(app, "home-manage-settings")
        for _ in 0..<8 where !row.isHittable { app.swipeUp() }
        open(app, row, ready: "home-settings-content", name: "home-settings")
        expandSheet(app, title: "Home Settings")
        let content = element(app, "home-settings-content")
        let models = app.buttons["settings-section-model-open"], tools = element(app, "settings-row-tools.active")
        XCTAssertTrue(models.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(tools.waitForExistence(timeout: 5), app.debugDescription)
        shot("1478-home-settings-\(name)")
        // The Tools row names its card; the only "Tools" text is the row's own title.
        XCTAssertEqual(content.staticTexts.matching(NSPredicate(format: "label == 'Tools'")).count, 1, content.debugDescription)
        XCTAssertGreaterThanOrEqual(tools.buttons["settings-row-tools.active-source"].frame.height, 44)
        let cards = [models, tools, content.buttons["Configuration"], content.buttons["Changes"]]
        for card in cards.dropFirst() { for _ in 0..<4 where !card.isHittable { app.swipeUp() } }
        shot("1478-home-settings-\(name)-bottom")
        let gaps = zip(cards, cards.dropFirst()).map { $1.frame.minY - $0.frame.maxY }
        XCTAssertEqual(gaps.max()! - gaps.min()!, 0, accuracy: 1, "One gap between every card: \(gaps)")
        XCTAssertLessThan(gaps.max()!, 12, "Cards sit tightly together: \(gaps)")
    }

    /// Session Settings shares Home Settings' container: the same card gap (#1478).
    @MainActor func testSessionSettingsCardsShareHomeGap() {
        continueAfterFailure = false
        for (appearance, size) in [("light", "UICTContentSizeCategoryL"), ("dark", "UICTContentSizeCategoryL"),
                                   ("light", "UICTContentSizeCategoryAccessibilityL")] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-session-configuration-fixture", "-fixture-appearance", appearance,
                                   "-UIPreferredContentSizeCategoryName", size]
            app.launch()
            XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 10))
            app.buttons["Stop session"].tap()
            let link = app.buttons["chat-settings-link"]
            for _ in 0..<12 where !link.isHittable { app.swipeUp() }
            link.tap()
            expandSheet(app, title: "Session Settings")
            let content = element(app, "session-settings-content")
            let configuration = content.buttons["Configuration"], changes = content.buttons["Changes"]
            XCTAssertTrue(configuration.waitForExistence(timeout: 8), app.debugDescription)
            let suffix = size.contains("Accessibility") ? "ax-large" : appearance
            shot("1478-session-settings-\(suffix)")
            for _ in 0..<6 where !changes.isHittable { app.swipeUp() }
            shot("1478-session-settings-\(suffix)-bottom")
            XCTAssertLessThan(changes.frame.minY - configuration.frame.maxY, 12, "Session Settings shares the tight card gap")
            app.terminate()
        }
    }

    /// Brings a settings sheet to its large detent.
    @MainActor private func expandSheet(_ app: XCUIApplication, title text: String) {
        let title = app.navigationBars.staticTexts[text].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), app.debugDescription)
        // A drag that starts while the sheet is still presenting is lost: wait
        // until the title stops moving first.
        var last = title.frame.minY
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.3)
            let now = title.frame.minY
            if abs(now - last) < 0.5 { break }
            last = now
        }
        // Drag by the bar's empty leading edge, as `expand` does. At accessibility
        // sizes a press on the bar can open the large-content viewer instead, so
        // later tries flick the scrolled-to-top content below it or swipe it up.
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        for attempt in 0..<6 where title.frame.minY > 120 {
            switch attempt % 3 {
            case 0:
                origin.withOffset(CGVector(dx: 60, dy: title.frame.midY))
                    .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: 60, dy: 20)))
            case 1:
                origin.withOffset(CGVector(dx: 60, dy: title.frame.maxY + 30))
                    .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 60, dy: 20)),
                           withVelocity: .fast, thenHoldForDuration: 0)
            default:
                app.swipeUp()
            }
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "frame.minY < 120"), object: title)], timeout: 2)
        }
        XCTAssertLessThan(title.frame.minY, 120, "\(text) reached its large detent")
    }

    @MainActor private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Private simulator comparison, with the same large-detent native list owner
    /// and working row navigation, not a mockup or source-string styling check.
    @MainActor
    func testPagedListPreview() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        let ring = app.buttons["session-context-button"]
        XCTAssertTrue(waitFor(ring, "enabled == true"))
        open(app, ring, ready: "home-manage-state", name: "manage")
        expand(app, done: "home-sheet-done-manage")
        open(app, element(app, "home-manage-memory-browser"), ready: "home-memory-row-39", name: "memory")
        expand(app, done: "home-sheet-done-memory")
        XCTAssertTrue(element(app, "home-memory-older-top").isHittable)
        keep("1214-memory")
        element(app, "home-memory-older-top").tap()
        XCTAssertTrue(element(app, "home-memory-summary-0-16").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "home-memory-row-39").exists)
        element(app, "home-memory-newer-top").tap()
        XCTAssertTrue(element(app, "home-memory-row-39").waitForExistence(timeout: 5))
        app.buttons["home-sheet-done-memory"].tap()
        open(app, element(app, "home-manage-tasks"), ready: "home-task-active", name: "tasks")
        expand(app, done: "home-sheet-done-tasks")
        XCTAssertTrue(element(app, "home-tasks-range-top").exists)
        keep("1214-tasks")
        app.terminate()
        app.launchArguments = ["-tron-session-configuration-fixture", "-fixture-appearance", "light"]
        app.launch()
        XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 10))
        app.buttons["Stop session"].tap()
        let history = app.buttons["Session History"]
        for _ in 0..<12 where !history.isHittable { app.swipeUp() }
        XCTAssertTrue(history.isHittable); history.tap()
        XCTAssertTrue(app.buttons["Actions for Nested history prompt"].waitForExistence(timeout: 10))
        let done = app.buttons.matching(NSPredicate(format: "label == 'Done'")).allElementsBoundByIndex.last(where: \.isHittable)!
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: 60, dy: done.frame.midY))
            .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: 60, dy: 20)))
        keep("1214-history")
    }

    /// Real socket/UI boundary: failed navigation retains the installed window;
    /// retry replaces it, reverse reads restore the right cursor, and detail
    /// dismissal keeps a scrolled viewport rather than re-reading/resetting it.
    @MainActor
    func testHomeCursorPagesRetryAndRetainScroll() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-paging", "-home-browser-paging"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        let ring = app.buttons["session-context-button"]
        XCTAssertTrue(waitFor(ring, "enabled == true"))
        open(app, ring, ready: "home-manage-state", name: "manage")
        expand(app, done: "home-sheet-done-manage")
        open(app, element(app, "home-manage-memory-browser"), ready: "home-memory-row-39", name: "memory")
        expand(app, done: "home-sheet-done-memory")
        let memoryRow = app.buttons["home-memory-row-39"]
        let memoryWidth = memoryRow.frame.width
        let memoryY = memoryRow.frame.minY
        app.buttons["home-memory-older-top"].tap()
        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 5))
        XCTAssertTrue(memoryRow.exists)
        XCTAssertEqual(memoryRow.frame.minY, memoryY, accuracy: 2, "Failed paging keeps the viewport")
        keep("1214-memory-page-error")
        app.buttons["Retry"].tap()
        XCTAssertTrue(app.buttons["home-memory-summary-0-16"].waitForExistence(timeout: 5))
        XCTAssertFalse(memoryRow.exists, "Page replacement never accumulates duplicate old rows")
        app.buttons["home-memory-newer-top"].tap()
        XCTAssertTrue(memoryRow.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "home-memory-row-39").count, 1)
        app.buttons["home-sheet-done-memory"].tap()

        open(app, element(app, "home-manage-tasks"), ready: "home-task-active", name: "tasks")
        expand(app, done: "home-sheet-done-tasks")
        XCTAssertEqual(app.buttons["home-task-active"].frame.width, memoryWidth, accuracy: 2, "Shared row layout has one content width")
        let firstY = app.buttons["home-task-active"].frame.minY
        app.buttons["home-tasks-older-top"].tap()
        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["home-task-active"].exists)
        XCTAssertEqual(app.buttons["home-task-active"].frame.minY, firstY, accuracy: 2)
        app.buttons["Retry"].tap()
        XCTAssertTrue(app.buttons["home-task-paged-20"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["home-task-active"].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "home-task-paged-20").count, 1)
        keep("1214-tasks-page-two")

        let scrolled = app.buttons["home-task-paged-25"]
        for _ in 0..<8 where !scrolled.isHittable { app.swipeUp() }
        XCTAssertTrue(scrolled.isHittable)
        let retainedY = scrolled.frame.minY
        scrolled.tap()
        XCTAssertTrue(element(app, "home-task-detail").waitForExistence(timeout: 5))
        app.buttons["home-sheet-done-task"].tap()
        XCTAssertTrue(scrolled.waitForExistence(timeout: 5))
        XCTAssertEqual(scrolled.frame.minY, retainedY, accuracy: 3, "Detail dismissal retains the scrolled row")
        // The detail itself reads once; record after it closes, then prove no
        // periodic refresh changes the installed parent window.
        let after = reads(app)
        assertNoReads(app, since: after, "Returning to a task page does not refresh it")
        for _ in 0..<8 where !app.buttons["home-tasks-older-top"].isHittable { app.swipeDown() }
        app.buttons["home-tasks-older-top"].tap()
        XCTAssertTrue(app.buttons["home-task-paged-40"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["home-task-paged-20"].exists)
        XCTAssertFalse(app.buttons["home-tasks-older-top"].exists, "The last page is exhausted")
        app.buttons["home-tasks-newer-top"].tap()
        XCTAssertTrue(app.buttons["home-task-paged-20"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "home-task-paged-20").count, 1)
        app.buttons["home-tasks-newer-top"].tap()
        XCTAssertTrue(app.buttons["home-task-active"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["home-tasks-newer-top"].exists)
        keep("1214-tasks-restored-first-page")
    }

    @MainActor
    func testHomeSheetsJourney() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        let ring = app.buttons["session-context-button"]
        XCTAssertTrue(ring.waitForExistence(timeout: 10))
        XCTAssertTrue(waitFor(ring, "label CONTAINS 'Manage Home'"))
        XCTAssertTrue(waitFor(ring, "enabled == true"))
        open(app, ring, ready: "home-manage-state", name: "manage")
        keep("00-manage-medium")
        expand(app, done: "home-sheet-done-manage")
        keep("01-manage")

        // Manage Home's top card is Home's context: the state pill and the last
        // activation, a section-segmented bar, then the legend above the metrics.
        // There is no separate Home Context sheet.
        XCTAssertFalse(element(app, "home-manage-context").exists, "Home Context is part of Manage Home")
        XCTAssertTrue(element(app, "context-segmented-bar").exists)
        XCTAssertTrue(element(app, "context-segment-memory").label.contains("260 summaries"))
        XCTAssertTrue(element(app, "home-context-activation").label.hasPrefix("Your message"))
        let cacheHit = element(app, "home-context-breakdown").descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Cache Hit'")).firstMatch
        XCTAssertTrue(cacheHit.exists)
        XCTAssertLessThanOrEqual(element(app, "context-segment-input").frame.maxY, cacheHit.frame.minY, "The legend sits above the metrics")

        // Home Settings is its own container below the rows container.
        app.swipeUp()
        let settings = element(app, "home-manage-settings"), tasks = element(app, "home-manage-tasks")
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        XCTAssertFalse(element(app, "home-manage-permissions").exists)
        XCTAssertGreaterThan(settings.frame.minY, tasks.frame.maxY + 8, "Home Settings sits in a separate container")
        keep("01b-manage-bottom")
        app.swipeDown()

        // Each sub-sheet's title takes the tint of the Manage Home row that opened it
        // (#925), through the shared settings theme, not Manage Home's own green.
        let rowTint = ink(app, element(app, "home-manage-memory-browser"), leading: 56)
        let manageTint = ink(app, app.navigationBars.staticTexts["Manage Home"].firstMatch)

        // Memory: the recent messages and the summaries Home sees, without raw kind prefixes.
        open(app, element(app, "home-manage-memory-browser"), ready: "home-memory-row-39", name: "memory")
        expand(app, done: "home-sheet-done-memory")
        assertTitleTint(app, "Memory", matches: rowTint, not: manageTint)
        XCTAssertTrue(element(app, "home-memory-viewport").exists)
        XCTAssertTrue(element(app, "home-memory-range-top").exists)
        XCTAssertTrue(element(app, "home-memory-summary-32-2").exists)
        XCTAssertTrue(element(app, "home-memory-row-39").label.contains("Task result:"))
        let prefixed = NSPredicate(format: "label BEGINSWITH 'user:' OR label BEGINSWITH 'talk:' OR label BEGINSWITH 'echo:' OR label BEGINSWITH 'event:'")
        XCTAssertEqual(app.staticTexts.matching(prefixed).count, 0, "Memory rows never show raw kind prefixes")
        let markdown = element(app, "home-memory-row-37")
        XCTAssertTrue(markdown.label.contains("garden review"), markdown.label)
        XCTAssertFalse(markdown.label.contains("**") || markdown.label.contains("`"), "Memory previews render markdown: \(markdown.label)")
        keep("03-memory")
        open(app, element(app, "home-memory-row-39"), ready: "home-memory-detail", name: "memory-item")
        XCTAssertFalse(element(app, "home-memory-remembered").exists, "A summary equal to the message is not repeated")
        keep("04-memory-item")
        app.buttons["home-sheet-done-memory-item"].tap()
        app.buttons["home-sheet-done-memory"].tap()

        // Chapters: a chapter opens from the loaded row, and returning reads nothing again.
        open(app, element(app, "home-manage-chapters"), ready: "home-chapter-1", name: "chapters")
        expand(app, done: "home-sheet-done-chapters")
        assertTitleTint(app, "Chapters", matches: rowTint, not: manageTint)
        // The title names the list; only the intro line sits above the rows.
        let listTitle = app.navigationBars.staticTexts["Chapters"].firstMatch.frame, firstRow = element(app, "home-chapter-2").frame
        let headers = app.staticTexts.matching(NSPredicate(format: "label == 'Chapters'")).allElementsBoundByIndex
            .filter { $0.frame.minY > listTitle.maxY && $0.frame.maxY <= firstRow.minY }
        XCTAssertTrue(headers.isEmpty, "No section header repeats the title")
        XCTAssertTrue(app.staticTexts["Newest first. Sealed chapters stay readable and refuse changes."].exists)
        keep("05-chapters")
        let chaptersLoaded = reads(app)
        open(app, element(app, "home-chapter-2"), ready: "home-chapter-detail", name: "chapter")
        XCTAssertEqual(reads(app), chaptersLoaded, "A chapter opens from the row already loaded")
        XCTAssertFalse(element(app, "home-chapter-open-transcript").exists, "The current chapter is this chat and has no transcript row")
        app.buttons["home-sheet-done-chapter"].tap()
        XCTAssertTrue(element(app, "home-chapter-1").exists, "Chapters keeps its rows while a child closes")
        XCTAssertFalse(element(app, "home-sheet-loading").exists, "Returning to Chapters shows no loading state")
        assertNoReads(app, since: chaptersLoaded, "Returning to Chapters re-reads nothing")
        open(app, element(app, "home-chapter-1"), ready: "home-chapter-detail", name: "chapter-sealed")
        expand(app, done: "home-sheet-done-chapter")
        XCTAssertTrue(element(app, "home-chapter-header").exists)
        XCTAssertTrue(element(app, "home-chapter-size").label.contains("hard limit"))
        XCTAssertTrue(element(app, "home-chapter-topics").exists)
        XCTAssertTrue(element(app, "home-chapter-open-transcript").exists)
        keep("06-chapter-sealed")
        // A topic row previews one line; tapping it opens the whole topic, markdown rendered.
        let topic = element(app, "home-chapter-topic-0")
        XCTAssertTrue(topic.label.hasSuffix("…"), topic.label)
        XCTAssertFalse(topic.label.contains("**"), topic.label)
        open(app, topic, ready: "home-reading-text", name: "topic")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'shared'")).firstMatch.exists, app.debugDescription)
        assertTitleTint(app, "Topic", matches: rowTint, not: manageTint)
        keep("06b-chapter-topic")
        closeTop(app)
        XCTAssertTrue(element(app, "home-chapter-detail").waitForExistence(timeout: 3))

        // A previous chapter's memory: its summary lines, opened down to one message.
        open(app, element(app, "home-chapter-browse-memory"), ready: "home-memory-summary-28-4", name: "chapter-memory")
        expand(app, done: "home-sheet-done-memory")
        XCTAssertFalse(element(app, "home-memory-row-39").exists, "Chapter 1's memory holds only its own lines")
        keep("07-chapter-memory")
        open(app, element(app, "home-memory-summary-28-4"), ready: "home-memory-summary-detail", name: "memory-summary")
        expand(app, done: "home-sheet-done-memory-summary")
        XCTAssertTrue(element(app, "home-memory-summary-28-2").exists)
        XCTAssertTrue(element(app, "home-memory-summary-30-2").exists)
        keep("07b-memory-summary")
        open(app, element(app, "home-memory-summary-30-2").firstMatch, ready: "home-memory-row-31", name: "memory-half")
        open(app, element(app, "home-memory-row-31"), ready: "home-memory-detail", name: "memory-half-item")
        let memoryOpened = reads(app)
        app.buttons["home-sheet-done-memory-item"].tap()
        assertNoReads(app, since: memoryOpened, "Returning to a summary re-reads nothing")
        for _ in 0..<2 { app.buttons["home-sheet-done-memory-summary"].firstMatch.tap() }
        app.buttons["home-sheet-done-memory"].tap()
        app.buttons["home-sheet-done-chapter"].tap()
        XCTAssertTrue(element(app, "home-chapter-1").waitForExistence(timeout: 3))
        assertNoReads(app, since: memoryOpened, "Closing the memory and chapter sheets re-reads nothing")
        let finalReads = reads(app)
        app.buttons["home-sheet-done-chapters"].tap()

        // Tasks: shared rows; the detail has no Stop, Steer or Reload, and opens the worker session.
        open(app, element(app, "home-manage-tasks"), ready: "home-task-active", name: "tasks")
        expand(app, done: "home-sheet-done-tasks")
        assertTitleTint(app, "Tasks", matches: rowTint, not: manageTint)
        let tasksTitle = app.navigationBars.staticTexts["Tasks"].firstMatch.frame, firstTask = element(app, "home-task-active").frame
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == 'Tasks'")).allElementsBoundByIndex
            .filter { $0.frame.minY > tasksTitle.maxY && $0.frame.maxY <= firstTask.minY }.isEmpty, "No section header repeats the title")
        XCTAssertTrue(element(app, "home-task-active").label.contains("Validating settings changes"))
        XCTAssertFalse(element(app, "home-task-active").label.contains("Optional("), "The timestamp renders as a relative date, not Swift debug text")
        keep("08-tasks")
        open(app, element(app, "home-task-active"), ready: "home-task-detail", name: "task")
        expand(app, done: "home-sheet-done-task")
        for removed in ["home-task-stop", "home-task-steer", "home-task-steer-send", "home-task-reload", "home-tasks-reload", "home-task-open-worker"] {
            XCTAssertFalse(element(app, removed).exists, removed)
        }
        XCTAssertTrue(element(app, "home-task-header").exists)
        XCTAssertTrue(element(app, "home-task-spend").label.contains("12 in"))
        // Worker values read as the standard row's subtitle, never a monospaced trailing value.
        let model = element(app, "home-task-model")
        XCTAssertTrue(model.label.contains("Model") && model.label.contains("Claude Opus 5.5"), model.label)
        // The brief previews its opening lines with markdown rendered, and opens whole from View All.
        let brief = element(app, "home-task-brief")
        XCTAssertTrue(brief.exists)
        XCTAssertFalse(app.buttons["Show all"].exists, "The brief never expands in place")
        let checkin = element(app, "home-task-checkin")
        XCTAssertTrue(checkin.exists)
        XCTAssertTrue(checkin.label.contains("Latest check-in") && checkin.label.contains("Gateway journey passed") && checkin.label.contains("Review native screenshots"), checkin.label)
        keep("09-task-detail")
        open(app, element(app, "home-task-brief-view-all"), ready: "home-reading-text", name: "brief")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'settings model doc'")).firstMatch.exists, "View All shows the whole brief")
        assertTitleTint(app, "Brief", matches: rowTint, not: manageTint)
        keep("09b-task-brief")
        closeTop(app)
        XCTAssertTrue(element(app, "home-task-detail").waitForExistence(timeout: 3))
        app.buttons["home-task-open-session"].tap()
        XCTAssertTrue(waitFor(app.staticTexts["fixture.home-opened-session"], "label CONTAINS 'opened-session:worker-session'"))
        XCTAssertFalse(app.buttons["Manage Home"].exists, "The worker chat is an ordinary session and must not claim Home")

        let report = XCTAttachment(string: String(data: try! JSONSerialization.data(withJSONObject: [
            "openMs": timings, "homeReadsAfterChapterJourney": finalReads,
        ], options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
        report.name = "home-sheet-measurements"; report.lifetime = .keepAlways
        add(report)
    }

    /// Home's composer offers the user-level skills and prompt templates its Gateway
    /// catalog lists, through the same `@` and `/` pickers as an ordinary chat, and the
    /// inserted skills and prompts are sent together, in pick order, on the logical
    /// Home route as that message's resources (#936, #311).
    @MainActor
    func testHomeComposerOffersUserSkillsAndPrompts() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        XCTAssertTrue(waitFor(app.staticTexts["fixture.home-opened-session"], "label CONTAINS 'opened-session:home-session'"))
        let composer = app.textViews["Message input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()

        composer.typeText("@")
        let skill = app.buttons.matching(NSPredicate(format: "label CONTAINS 'wordcraft' AND label CONTAINS 'User'")).firstMatch
        XCTAssertTrue(skill.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'jev'")).firstMatch.exists)
        keep("10-home-composer-skills")

        composer.typeText(XCUIKeyboardKey.delete.rawValue + "/")
        let prompt = app.buttons.matching(NSPredicate(format: "label CONTAINS 'daily-brief' AND label CONTAINS 'User'")).firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 5), app.debugDescription)
        keep("11-home-composer-prompts")

        prompt.tap()
        let stagedChips = app.descendants(matching: .any).matching(identifier: "composer.staged-chip")
        XCTAssertTrue(stagedChips.firstMatch.waitForExistence(timeout: 5), app.debugDescription)

        // Each pick appends a chip in order; picking a staged resource again adds
        // nothing, and one chip is removed alone (#311).
        func pick(_ trigger: String, _ name: String) {
            composer.typeText(trigger)
            let entry = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS 'User'", name)).firstMatch
            XCTAssertTrue(entry.waitForExistence(timeout: 5), app.debugDescription)
            entry.tap()
        }
        pick("@", "wordcraft")
        pick("/", "weekly-review")
        pick("/", "daily-brief")
        pick("@", "jev")
        XCTAssertTrue(waitFor(stagedChips, count: 4, timeout: 5), app.debugDescription)
        app.buttons["Remove resource, Jev"].tap()
        XCTAssertTrue(waitFor(stagedChips, count: 3, timeout: 5), app.debugDescription)
        composer.typeText("inbox")
        keep("12-home-composer-resources-inserted")
        let send = app.buttons["Send message"]
        XCTAssertTrue(waitFor(send, "enabled == true", timeout: 5))
        send.tap()
        XCTAssertTrue(waitFor(app.staticTexts["fixture.home-prompt-route"],
                              "label CONTAINS 'prompt-route:home.prompt:prompt:daily-brief+skill:wordcraft+prompt:weekly-review:inbox'"),
                      app.staticTexts["fixture.home-prompt-route"].label)
        keep("13-home-composer-resources-sent")
    }

    /// The transcript host outlives recycled rows. Its previous selection and
    /// expanded detent must not become the next historical chip's initial state.
    @MainActor
    func testHistoricalToolSheetsReopenAtMediumWithoutLeakingSelection() {
        checkHistoricalToolSheets(dark: false)
    }

    @MainActor
    func testHistoricalToolSheetsReopenAtMediumWithoutLeakingSelectionInDarkMode() {
        checkHistoricalToolSheets(dark: true)
    }

    @MainActor private func checkHistoricalToolSheets(dark: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-tool-transcript", "-home-tool-paged-transcript"]
            + (dark ? ["-home-dark"] : [])
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        XCTAssertTrue(waitFor(app.staticTexts["fixture.home-opened-session"], "label CONTAINS 'opened-session:home-session'"))

        for (index, selection) in ["Memory search", "Date", "Memory search"].enumerated() {
            let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", selection + ", Completed,")).firstMatch
            // Alternate across historical rows, not a fixture-only sheet host.
            for _ in 0..<12 where !(chip.exists && chip.isHittable) {
                if selection == "Memory search" { app.swipeUp() } else { app.swipeDown() }
            }
            open(app, chip, ready: "home-tool-detail", name: "historical-\(index)")
            let outcome = element(app, "home-tool-outcome")
            XCTAssertTrue(outcome.label.hasSuffix(selection == "Date" ? "Found" : "2 matches"),
                          "The selected chip must render its own payload, not the previous tool: \(app.debugDescription)")
            let done = app.buttons.matching(NSPredicate(format: "label == 'Done'")).allElementsBoundByIndex.last(where: \.isHittable)!
            XCTAssertGreaterThan(done.frame.minY, app.windows.firstMatch.frame.height * 0.35,
                                 "Every fresh tool presentation starts medium even after a previous tool expanded")
            keep("1309-\(index)-initial-medium")
            if index == 1 {
                inspectHistoricalToolRequest(app)
                XCTAssertGreaterThan(done.frame.minY, app.windows.firstMatch.frame.height * 0.35,
                                     "A nested info/JSON round trip retains the parent's medium detent")
            }
            let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: app.windows.firstMatch.frame.midX, dy: done.frame.minY - 12))
                .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: app.windows.firstMatch.frame.midX, dy: 20)))
            keep("1309-\(index)-after-expansion-gesture")
            let expanded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in done.frame.minY < 120 }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 5), .completed,
                           "The native sheet must actually expand before testing leakage; Done frame: \(done.frame)")

            if index == 0 {
                inspectHistoricalToolRequest(app)
                XCTAssertLessThan(done.frame.minY, 120, "A nested info/back round trip retains the parent's chosen large detent")
                XCUIDevice.shared.press(.home)
                app.activate()
                XCTAssertTrue(element(app, "home-tool-detail").waitForExistence(timeout: 10))
                XCTAssertTrue(element(app, "home-tool-outcome").label.hasSuffix("2 matches"))
                XCTAssertLessThan(done.frame.minY, 120, "Background/foreground retains the chosen large detent")
            }
            closeTop(app)
            XCTAssertTrue(waitFor(element(app, "home-tool-detail"), "exists == false", timeout: 5))
        }
        // These calls are absent from the authoritative live tail. The native
        // history RPC installs their request/result before their chips can open.
        toolSheet(app, "paged-zoom", chip: "Zoom, Completed", index: 1, outcome: "Opened") {
            XCTAssertTrue(self.element(app, "home-tool-line-1122+2").exists)
        }
        toolSheet(app, "paged-task", chip: "Task, Completed", index: 2, outcome: "Active") {
            XCTAssertTrue(self.element(app, "home-tool-row-Latest check-in").label.contains("Gateway journey passed"))
        }
        for index in 0..<2 {
            // These canonical records deliberately omit labels as well as origin.
            // Raw names stay lowercase; renderer admission must not depend on labels.
            toolSheet(app, "paged-single-zoom-\(index)", chip: "zoom, Completed", index: 0, outcome: "Opened") {
                XCTAssertTrue(self.element(app, "home-tool-line-3539+0").exists)
            }
            let list = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'task, Completed,'")).firstMatch
            for _ in 0..<12 where !(list.exists && list.isHittable) { app.swipeDown() }
            list.tap()
            XCTAssertTrue(app.buttons["Technical details"].waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertFalse(element(app, "home-tool-detail").exists,
                           "A successful Task list catalog is generic, not a single-task custom status")
            XCTAssertTrue(app.staticTexts["list"].exists, app.debugDescription)
            keep("1309-task-list-generic-\(index)")
            closeTop(app)
            XCTAssertTrue(app.buttons["Technical details"].waitForNonExistence(timeout: 5))
        }
    }

    @MainActor private func inspectHistoricalToolRequest(_ app: XCUIApplication) {
        app.buttons["Technical details"].tap()
        let request = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Inspect Request JSON,'")).firstMatch
        XCTAssertTrue(request.waitForExistence(timeout: 5), app.debugDescription)
        request.tap()
        XCTAssertTrue(app.staticTexts["Request JSON"].waitForExistence(timeout: 5))
        let jsonDone = app.buttons.matching(NSPredicate(format: "label == 'Done'")).allElementsBoundByIndex.last(where: \.isHittable)!
        XCTAssertGreaterThan(jsonDone.frame.minY, app.windows.firstMatch.frame.height * 0.35,
                             "The JSON reader keeps its own existing medium-first policy, even over a large parent")
        closeTop(app)
        XCTAssertTrue(request.waitForExistence(timeout: 5))
        closeTop(app)
        XCTAssertTrue(element(app, "home-tool-detail").waitForExistence(timeout: 5))
    }

    /// Every Home tool call opens its purpose-built detail from the Home transcript, and
    /// the learned profile opens from Manage Home's Profile row (#957). Failure modes: a
    /// Home tool's detail fell back to raw JSON; a schema-rejected or refused call did not
    /// state its error; the brief, report or memory line was not readable Markdown; the
    /// Profile row was missing, below Memory, or its sheet did not list each item by kind.
    @MainActor
    func testHomeToolDetailSheetsAndProfile() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-tool-transcript"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        XCTAssertTrue(waitFor(app.staticTexts["fixture.home-opened-session"], "label CONTAINS 'opened-session:home-session'"))

        // Newest first, so each chip is revealed by scrolling toward older messages.
        toolSheet(app, "memory-search", chip: "Memory search, Completed", index: 0, outcome: "2 matches") {
            XCTAssertTrue(self.element(app, "home-tool-row-Range").label.contains("1100–1131"))
            self.assertReads(app, self.element(app, "home-tool-line-1110+0"), contains: "feat/890-sheets")
        }
        toolSheet(app, "date", chip: "Date, Completed", index: 0, outcome: "Found") {
            XCTAssertTrue(self.element(app, "home-tool-row-Date").label.contains("2026"))
            XCTAssertTrue(self.element(app, "home-tool-row-Time").exists)
        }
        toolSheet(app, "zoom-invalid", chip: "Zoom, Completed", index: 0, outcome: "Not found") {
            XCTAssertTrue(self.allText(self.element(app, "home-tool-failure")).contains("No line 7+3"))
        }
        toolSheet(app, "zoom", chip: "Zoom, Completed", index: 1, outcome: "Opened") {
            XCTAssertTrue(self.element(app, "home-tool-line-1122+2").exists)
            self.assertReads(app, self.element(app, "home-tool-line-1120+2"), contains: "handoff")
        }
        toolSheet(app, "profile-refused", chip: "Profile, Completed", index: 0, outcome: "Refused") {
            XCTAssertTrue(self.allText(self.element(app, "home-tool-failure")).contains("retire requires reason"))
        }
        toolSheet(app, "profile-supersede", chip: "Profile, Completed", index: 1, outcome: "Saved · Inferred") {
            XCTAssertTrue(self.element(app, "home-tool-row-Supersedes note").label.contains("3f3264c8"))
            XCTAssertTrue(self.allText(self.element(app, "home-tool-text-previous")).contains("Chat over Project"))
        }
        toolSheet(app, "profile-learn", chip: "Profile, Completed", index: 2, outcome: "Saved · Inferred") {
            XCTAssertTrue(self.element(app, "home-tool-row-Kind").label.contains("Preference"))
            self.assertMarkdown(self.element(app, "home-tool-text-text"), contains: "screenshots")
        }
        toolSheet(app, "settings-change", chip: "Settings, Completed", index: 0, outcome: "Pending approval") {
            XCTAssertTrue(self.element(app, "home-tool-row-Set").label.contains("3 → 6"), self.element(app, "home-tool-row-Set").label)
            XCTAssertTrue(self.element(app, "home-tool-row-Layer").label.contains("Home profile"))
            XCTAssertTrue(self.element(app, "home-tool-row-Tier").label.contains("Approve"))
        }
        toolSheet(app, "settings-resolve", chip: "Settings, Completed", index: 1, outcome: "Read") {
            XCTAssertTrue(self.element(app, "home-tool-row-model.ref[role=worker]").label.contains("Claude Opus 5.5 · Home profile"))
        }
        toolSheet(app, "task-rejected", chip: "Task, Failed", index: 0, outcome: "Rejected") {
            let failure = self.allText(self.element(app, "home-tool-failure"))
            XCTAssertTrue(failure.contains("Rejected before it ran"), failure)
            XCTAssertTrue(failure.contains("root: must not have additional properties"), failure)
            XCTAssertFalse(failure.contains("Received arguments"), "The schema issues, not the raw arguments: \(failure)")
        }
        toolSheet(app, "task-steer", chip: "Task, Completed", index: 0, outcome: "Accepted") {
            self.assertMarkdown(self.element(app, "home-tool-text-message"), contains: "Profile")
        }
        toolSheet(app, "task-report", chip: "Task, Completed", index: 1, outcome: "Final") {
            XCTAssertTrue(self.element(app, "home-tool-row-Page").label.contains("Bytes 0"))
            self.assertMarkdown(self.element(app, "home-tool-text-report"), contains: "PR #773")
        }
        toolSheet(app, "task-status", chip: "Task, Completed", index: 2, outcome: "Active") {
            XCTAssertTrue(self.element(app, "home-tool-row-Latest check-in").label.contains("Gateway journey passed"))
            XCTAssertTrue(self.element(app, "home-tool-row-Tokens").label.contains("in"))
            XCTAssertTrue(self.element(app, "home-tool-row-Subagents").label.contains("3 started"))
            XCTAssertTrue(self.element(app, "home-tool-row-Model").label.contains("Claude Opus 5.5"))
        }
        toolSheet(app, "delegate-refused", chip: "Delegate, Failed", index: 0, outcome: "Refused") {
            XCTAssertTrue(self.allText(self.element(app, "home-tool-failure")).contains("thinking needs a model"))
        }
        toolSheet(app, "delegate", chip: "Delegate, Completed", index: 0, outcome: "Admitted") {
            XCTAssertTrue(self.element(app, "home-tool-row-Model").label.contains("Claude Opus 5.5 · Home profile"))
            self.assertMarkdown(self.element(app, "home-tool-text-brief"), contains: "Home tool detail sheets")
            // With medium-first presentation restored, expanding is not also a
            // body scroll. Bring the bottom reader action above the sheet edge.
            app.swipeUp()
            self.open(app, self.element(app, "home-tool-text-brief-view-all"), ready: "home-reading-text", name: "delegate-brief")
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Ask every decision'")).firstMatch.exists, "View All shows the whole brief")
            self.keep("tool-delegate-brief")
            self.closeTop(app)
        }

        // Manage Home's Profile row sits directly above Memory and opens the learned profile.
        let ring = app.buttons["session-context-button"]
        XCTAssertTrue(waitFor(ring, "enabled == true"))
        open(app, ring, ready: "home-manage-state", name: "manage")
        expand(app, done: "home-sheet-done-manage")
        let profileRow = element(app, "home-manage-profile"), memoryRow = element(app, "home-manage-memory-browser")
        XCTAssertTrue(profileRow.waitForExistence(timeout: 5))
        XCTAssertTrue(profileRow.label.contains("5 items · 2 confirmed · 3 inferred"), profileRow.label)
        XCTAssertLessThan(abs(profileRow.frame.maxY - memoryRow.frame.minY), 4, "Profile sits directly above Memory")
        keep("profile-00-manage-row")
        let rowTint = ink(app, profileRow, leading: 56)
        let manageTint = ink(app, app.navigationBars.staticTexts["Manage Home"].firstMatch)
        open(app, profileRow, ready: "home-profile-group-preference", name: "profile")
        expand(app, done: "home-sheet-done-profile")
        assertTitleTint(app, "Profile", matches: rowTint, not: manageTint)
        for kind in ["standing-decision", "delegation-default", "fact"] { XCTAssertTrue(element(app, "home-profile-group-\(kind)").exists, kind) }
        let item = element(app, "home-profile-item-9a364c45-34fe-4f0a-93e6-fc507e2b0bdc")
        XCTAssertTrue(item.label.contains("screenshots") && !item.label.contains("**"), item.label)
        XCTAssertTrue(item.label.contains("Inferred"), item.label)
        keep("profile-01-sheet")
        app.swipeUp()
        XCTAssertTrue(element(app, "home-profile-inactive").waitForExistence(timeout: 3))
        keep("profile-02-sheet-bottom")
        app.swipeDown()
        open(app, item, ready: "home-profile-item-detail", name: "profile-item")
        XCTAssertTrue(element(app, "home-profile-item-note-id").label.contains("9a364c45-34fe-4f0a-93e6-fc507e2b0bdc"))
        keep("profile-03-item")
    }

    /// The maintainer confirms, edits, replaces, retires and undoes learned-profile items
    /// from Manage Home › Profile (#966), and Home's own profile change shows in Changes
    /// with its detail and Undo. Every sheet keeps the shared rows, editors and toolbar tint.
    @MainActor
    func testProfileConfirmEditRetireAndUndo() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        let ring = app.buttons["session-context-button"]
        XCTAssertTrue(waitFor(ring, "enabled == true"))
        open(app, ring, ready: "home-manage-state", name: "manage")
        expand(app, done: "home-sheet-done-manage")
        open(app, element(app, "home-manage-profile"), ready: "home-profile-group-preference", name: "profile")
        expand(app, done: "home-sheet-done-profile")

        // Rows only open their item (#971): no row carries its own Confirm, and each row
        // spans its group so the text keeps the full width. Rows still say Inferred or Confirmed.
        let inferred = "9a364c45-34fe-4f0a-93e6-fc507e2b0bdc", confirmed = "6a26bfb7-f0d1-44ce-b0ae-9da01da3e55c"
        let rowActions = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'home-profile-confirm-' AND identifier != 'home-profile-confirm-all'"))
        XCTAssertEqual(rowActions.count, 0, "Profile rows carry no inline Confirm")
        let inferredRow = element(app, "home-profile-item-\(inferred)")
        XCTAssertTrue(inferredRow.label.contains("Inferred"), inferredRow.label)
        XCTAssertTrue(element(app, "home-profile-item-\(confirmed)").label.contains("Confirmed"))
        let group = element(app, "home-profile-group-preference")
        XCTAssertLessThan(abs(inferredRow.frame.width - group.frame.width), 2, "The row spans its group: \(inferredRow.frame) in \(group.frame)")
        XCTAssertTrue(element(app, "home-profile-confirm-all").label.contains("3 items"))
        keep("profile-edit-00-list")

        // An item is confirmed from its detail; the last change offers Undo, which restores it.
        open(app, inferredRow, ready: "home-profile-item-detail", name: "profile-item")
        expand(app, done: "home-sheet-done-profile-item")
        XCTAssertTrue(element(app, "home-profile-item-state").label.hasSuffix("Inferred"))
        element(app, "home-profile-item-confirm").tap()
        XCTAssertTrue(waitFor(element(app, "home-profile-item-state"), "label ENDSWITH 'Confirmed'"))
        XCTAssertTrue(element(app, "home-profile-last-change").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "home-profile-item-confirm").exists, "A confirmed item has nothing to confirm")
        keep("profile-edit-01-confirmed-undo")
        element(app, "home-profile-undo").tap()
        XCTAssertTrue(waitFor(element(app, "home-profile-item-state"), "label ENDSWITH 'Inferred'"))
        XCTAssertTrue(element(app, "home-profile-item-confirm").waitForExistence(timeout: 5))
        app.buttons["home-sheet-done-profile-item"].tap()
        XCTAssertTrue(waitFor(element(app, "home-profile-item-\(inferred)"), "label CONTAINS 'Inferred'"))

        // Confirm all asks first, then confirms every inferred item at once.
        element(app, "home-profile-confirm-all").tap()
        let confirmAll = app.buttons["Confirm all"].firstMatch
        XCTAssertTrue(confirmAll.waitForExistence(timeout: 5))
        keep("profile-edit-02-confirm-all")
        confirmAll.tap()
        XCTAssertTrue(app.staticTexts["Confirmed 3 items"].waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "home-profile-confirm-all").exists)
        element(app, "home-profile-undo").tap()
        XCTAssertTrue(waitFor(element(app, "home-profile-confirm-all"), "exists == true"))

        // An item's detail: Edit is the Settings value editor with Save, and an edit is confirmed.
        let decision = "00a809ef-ca94-49ec-938d-1a11444c657b"
        open(app, element(app, "home-profile-item-\(decision)"), ready: "home-profile-item-detail", name: "profile-item")
        expand(app, done: "home-sheet-done-profile-item")
        XCTAssertTrue(element(app, "home-profile-item-state").label.hasSuffix("Inferred"))
        assertToolbarTint(app, title: "Profile")
        keep("profile-edit-03-item")
        open(app, element(app, "home-profile-item-edit"), ready: "home-profile-editor-text", name: "profile-editor")
        let field = element(app, "home-profile-editor-text")
        field.tap()
        field.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        field.typeText("Settings layers, top wins: Chat > Home profile > Project > Mac.")
        XCTAssertTrue(app.buttons["tron-sheet-save"].isEnabled)
        keep("profile-edit-04-editor")
        assertToolbarTint(app, title: "Edit item")
        app.buttons["tron-sheet-save"].tap()
        XCTAssertTrue(waitFor(element(app, "home-profile-item-state"), "label ENDSWITH 'Confirmed'"))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'top wins: Chat > Home profile > Project > Mac.'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Edited: '")).firstMatch.exists)
        keep("profile-edit-05-edited")

        // Retire takes an optional reason, sits in the destructive role, and is undoable.
        open(app, element(app, "home-profile-item-retire"), ready: "home-profile-retire-reason", name: "profile-retire")
        element(app, "home-profile-retire-reason").tap()
        element(app, "home-profile-retire-reason").typeText("Covered by the settings design doc")
        assertToolbarTint(app, title: "Retire item", excluding: ["Retire"])
        keep("profile-edit-06-retire")
        app.buttons["home-profile-retire-confirm"].tap()
        XCTAssertTrue(waitFor(element(app, "home-profile-item-state"), "label ENDSWITH 'Retired'"))
        XCTAssertFalse(element(app, "home-profile-item-edit").exists, "A retired item no longer changes")
        keep("profile-edit-07-retired")
        element(app, "home-profile-undo").tap()
        XCTAssertTrue(waitFor(element(app, "home-profile-item-state"), "label ENDSWITH 'Confirmed'"))
        app.buttons["home-sheet-done-profile-item"].tap()
        // The Profile sheet re-read behind its item: the edited text is listed.
        XCTAssertTrue(waitFor(element(app, "home-profile-item-\(decision)"), "label CONTAINS 'top wins'"))
        app.buttons["home-sheet-done-profile"].tap()

        // Changes: Home's own learn is in the default feed, with its detail and Undo.
        let settings = element(app, "home-manage-settings")
        for _ in 0..<6 where !settings.isHittable { app.swipeUp() }
        settings.tap()
        let changes = app.buttons["Changes"].firstMatch
        XCTAssertTrue(changes.waitForExistence(timeout: 8))
        changes.tap()
        let entry = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'settings-change-' AND label CONTAINS 'Profile item'")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(entry.label.contains("Inferred preference"), entry.label)
        keep("profile-edit-08-changes")
        entry.tap()
        let undo = app.buttons["Undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        keep("profile-edit-09-change-detail")
    }

    /// Opens one Home tool call's detail from its transcript chip, checks the shared
    /// header's outcome, keeps both detents and closes it again.
    @MainActor private func toolSheet(_ app: XCUIApplication, _ name: String, chip label: String, index: Int, outcome: String,
                                      _ checks: () -> Void) {
        // Chips read "<Tool>, <Completed|Failed>, <duration>"; the transcript lists the newest first.
        let chips = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label + ","))
        let chip = chips.element(boundBy: index)
        for _ in 0..<12 where !(chip.exists && chip.isHittable) { app.swipeDown() }
        open(app, chip, ready: "home-tool-detail", name: "tool-\(name)")
        let pill = element(app, "home-tool-outcome")
        XCTAssertTrue(pill.label.hasSuffix(outcome), "\(name): outcome \(pill.label)")
        keep("tool-\(name)")
        let done = app.buttons.matching(NSPredicate(format: "label == 'Done'")).allElementsBoundByIndex.last(where: \.isHittable)
        if let done, done.frame.minY > 120 {
            let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: app.windows.firstMatch.frame.midX, dy: done.frame.minY - 12))
                .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: app.windows.firstMatch.frame.midX, dy: 20)))
            let expanded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in done.frame.minY < 120 }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 5), .completed)
        }
        checks()
        keep("tool-\(name)-large")
        closeTop(app)
        XCTAssertTrue(waitFor(element(app, "home-tool-detail"), "exists == false", timeout: 5), name)
    }

    /// A container's own label and every text inside it.
    @MainActor private func allText(_ element: XCUIElement) -> String {
        XCTAssertTrue(element.waitForExistence(timeout: 3), element.debugDescription)
        return ([element.label] + element.descendants(matching: .any).allElementsBoundByIndex.map(\.label)).joined(separator: " ")
    }

    /// Markdown is rendered: a text shows the words without the marks.
    @MainActor private func assertMarkdown(_ element: XCUIElement, contains text: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 3), text)
        let rendered = element.descendants(matching: .staticText).allElementsBoundByIndex.map(\.label)
            .contains { $0.contains(text) && !$0.contains("**") && !$0.contains("`") }
        XCTAssertTrue(rendered, "Markdown renders: \(allText(element))")
    }

    /// A memory line previews rendered Markdown and opens whole in the shared reader.
    @MainActor private func assertReads(_ app: XCUIApplication, _ line: XCUIElement, contains text: String) {
        XCTAssertTrue(line.waitForExistence(timeout: 3), text)
        XCTAssertFalse(line.label.contains("**"), line.label)
        open(app, line, ready: "home-reading-text", name: "line")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists, app.debugDescription)
        closeTop(app)
        XCTAssertTrue(element(app, "home-tool-detail").waitForExistence(timeout: 3))
    }

    // MARK: - Helpers

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Taps a row and waits for the sheet it opens, recording the tap-to-content time.
    @MainActor private func open(_ app: XCUIApplication, _ row: XCUIElement, ready: String, name: String) {
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(name)\n\(app.debugDescription)")
        let started = Date()
        row.tap()
        XCTAssertTrue(element(app, ready).waitForExistence(timeout: 8), "\(ready)\n\(app.debugDescription)")
        timings[name] = (Date().timeIntervalSince(started) * 1000).rounded()
    }

    /// The fixture's Home read counts; the fixture publishes each before answering it.
    @MainActor private func reads(_ app: XCUIApplication) -> String {
        app.staticTexts["fixture.home-read-counts"].label
    }

    /// Fails if any Home read is sent within the window: a sheet uncovered by its
    /// child must keep its page rather than re-read it.
    @MainActor private func assertNoReads(_ app: XCUIApplication, since baseline: String, _ message: String) {
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", baseline),
                                                object: app.staticTexts["fixture.home-read-counts"])
        changed.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 1.5), .completed, "\(message): \(reads(app))")
    }

    /// Drags the top sheet by its navigation bar (beside the title, never over content)
    /// so it settles at its large detent; its Done button names the sheet.
    @MainActor private func expand(_ app: XCUIApplication, done id: String) {
        let done = app.buttons[id].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), id)
        guard done.frame.minY > 120 else { return }
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: 60, dy: done.frame.midY))
            .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: 60, dy: 20)))
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "frame.minY < 120"), object: done)], timeout: 3)
    }

    private func waitFor(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 10) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)], timeout: timeout) == .completed
    }

    private func waitFor(_ query: XCUIElementQuery, count: Int, timeout: TimeInterval = 10) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", count), object: query)], timeout: timeout) == .completed
    }

    /// The average color of an element's saturated (inked) pixels: a title's
    /// glyphs or a row's icon, never the sheet material behind them.
    @MainActor private func ink(_ app: XCUIApplication, _ element: XCUIElement, leading: CGFloat? = nil) -> [Double] {
        XCTAssertTrue(element.waitForExistence(timeout: 5), app.debugDescription)
        var area = element.frame
        if let leading { area.size.width = leading }
        let window = app.windows.firstMatch.frame.width
        guard let source = XCUIScreen.main.screenshot().image.cgImage,
              let crop = source.cropping(to: area.applying(CGAffineTransform(scaleX: CGFloat(source.width) / window,
                                                                              y: CGFloat(source.width) / window))) else {
            XCTFail("No pixels for \(element)"); return [0, 0, 0]
        }
        let width = crop.width, height = crop.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            .draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        var sum = [0.0, 0.0, 0.0], count = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let rgb = [Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2])]
            guard rgb.max()! - rgb.min()! > 60 else { continue }
            for c in 0..<3 { sum[c] += Double(rgb[c]) / 255 }
            count += 1
        }
        XCTAssertGreaterThan(count, 10, "No inked pixels in \(element)")
        return sum.map { $0 / max(count, 1) }
    }

    /// Taps the Done of the top (hittable) sheet; the document reader has no Home id.
    @MainActor private func closeTop(_ app: XCUIApplication) {
        let done = app.buttons.matching(NSPredicate(format: "label == 'Done'")).allElementsBoundByIndex.last(where: \.isHittable)
        XCTAssertNotNil(done, app.debugDescription)
        done?.tap()
    }

    @MainActor private func assertTitleTint(_ app: XCUIApplication, _ title: String, matches row: [Double], not other: [Double]) {
        let tint = ink(app, app.navigationBars.staticTexts[title].firstMatch)
        let distance = { (a: [Double], b: [Double]) in zip(a, b).map { abs($0 - $1) }.max() ?? 1 }
        XCTAssertLessThan(distance(tint, row), 0.12, "\(title)'s title takes its Manage Home row's tint: \(tint) vs \(row)")
        XCTAssertGreaterThan(distance(tint, other), 0.12, "\(title)'s title is not Manage Home's own green: \(tint)")
    }

    /// Every kept step also proves the sheet's rows come from the shared row
    /// without a trailing chevron (#925): a row is tappable by its container.
    @MainActor private func keep(_ name: String) {
        XCTAssertFalse(XCUIApplication().images["chevron.right"].exists, "\(name): Manage Home rows carry no trailing chevron")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
