import XCTest

/// Manage Home and every sub-sheet, walked end to end on the hosted Home fixture
/// (#911). The journey proves the sheet structure, the memory hierarchy Home sees,
/// the removed task controls, and that returning to a loaded sheet reads nothing
/// again. Each step keeps a large-detent screenshot, and the open timings and read
/// counts are kept as a JSON attachment (`home-sheet-measurements`).
final class TronHomeSheetsUITests: XCTestCase {
    private var timings: [String: Double] = [:]

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
        XCTAssertLessThanOrEqual(element(app, "context-segment-free").frame.maxY, cacheHit.frame.minY, "The legend sits above the metrics")

        // Home Settings is its own container below the rows container.
        app.swipeUp()
        let settings = element(app, "home-manage-settings"), permissions = element(app, "home-manage-permissions")
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(settings.frame.minY, permissions.frame.maxY + 8, "Home Settings sits in a separate container")
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
        XCTAssertTrue(element(app, "home-memory-recent").exists)
        XCTAssertTrue(element(app, "home-memory-summaries").exists)
        XCTAssertTrue(element(app, "home-memory-summary-32-2").exists)
        XCTAssertTrue(element(app, "home-memory-row-39").label.hasPrefix("Result, Task result:"))
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
    /// catalog lists, through the same `@` and `/` pickers as an ordinary chat, and an
    /// inserted prompt is sent on the logical Home route as that message's resource (#936).
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
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'tron-jev'")).firstMatch.exists)
        keep("10-home-composer-skills")

        composer.typeText(XCUIKeyboardKey.delete.rawValue + "/")
        let prompt = app.buttons.matching(NSPredicate(format: "label CONTAINS 'daily-brief' AND label CONTAINS 'User'")).firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 5), app.debugDescription)
        keep("11-home-composer-prompts")

        prompt.tap()
        XCTAssertTrue(app.descendants(matching: .any)["composer.staged-chip"].waitForExistence(timeout: 5), app.debugDescription)
        composer.typeText("inbox")
        keep("12-home-composer-prompt-inserted")
        let send = app.buttons["Send message"]
        XCTAssertTrue(waitFor(send, "enabled == true", timeout: 5))
        send.tap()
        XCTAssertTrue(waitFor(app.staticTexts["fixture.home-prompt-route"], "label CONTAINS 'prompt-route:home.prompt:prompt:daily-brief:inbox'"),
                      app.staticTexts["fixture.home-prompt-route"].label)
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
