import XCTest

final class TronHomeSheetsUITests: XCTestCase {
    private var timings: [String: Double] = [:]

    @MainActor private func launchPolishManage(_ arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 15))
        app.buttons["home-pinned-row"].tap()
        let context = app.buttons["session-context-button"]
        XCTAssertTrue(waitFor(context, "enabled == true"))
        open(app, context, ready: "home-manage-state", name: "manage-polish")
        expand(app, done: "home-sheet-done-manage")
        return app
    }

    @MainActor func testManageHomeMemoryAndChapterCountValues() {
        let app = launchPolishManage(["-memory-boundary-regression"]); defer { app.terminate() }
        XCTAssertTrue(element(app, "home-manage-memory-browser").label.contains("40 messages · 11 lines in view"))
        XCTAssertTrue(element(app, "home-manage-chapters").label.contains("2 chapters · Active chapter 22% of soft limit"))
        shot("2063-count-values")
    }

    @MainActor func testMemoryBoundaryFollowsCanonicalSnapshotChange() {
        let app = launchPolishManage(["-memory-boundary-regression"]); defer { app.terminate() }
        open(app, element(app, "home-manage-memory-browser"), ready: "home-memory-row-39", name: "2063-before-change")
        expand(app, done: "home-sheet-done-memory")
        for _ in 0..<6 where !element(app, "home-memory-summary-32-2").isHittable { app.swipeUp(velocity: .slow) }
        open(app, element(app, "home-memory-summary-32-2"), ready: "home-memory-summary-detail", name: "2063-change")
        app.buttons["home-sheet-done-memory-summary"].tap()
        XCTAssertTrue(element(app, "home-memory-row-39").waitForExistence(timeout: 5))
        for _ in 0..<6 where !element(app, "home-memory-summary-32-4").isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(element(app, "home-memory-summary-32-4").waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(element(app, "home-memory-summary-32-2").exists, "Old view cursors and rows retire with the source snapshot")
        XCTAssertFalse(element(app, "home-memory-row-34").exists, "Messages 34 and 35 now belong to the coarser summary")
        XCTAssertTrue(element(app, "home-memory-resolution-boundary").exists)
        XCTAssertTrue(element(app, "home-memory-summary-32-4").label.contains("View line"))
        shot("2063-after-snapshot-change")
    }

    @MainActor func testRingAlignmentReviewLight() { captureRingAlignment("light", arguments: []) }
    @MainActor func testRingAlignmentReviewDark() { captureRingAlignment("dark", arguments: ["-home-dark"]) }
    @MainActor func testRingAlignmentReviewXXXL() {
        captureRingAlignment("xxxl", arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"])
    }

    @MainActor private func captureRingAlignment(_ name: String, arguments: [String]) {
        let app = launchPolishManage(arguments); defer { app.terminate() }
        let ring = element(app, "home-context-ring").frame
        let title = app.staticTexts["969K tokens left"].frame
        let detail = element(app, "home-context-detail").frame
        XCTAssertEqual(ring.midY, title.union(detail).midY, accuracy: 1.5,
                       "The ring centers on title and subtext together, not only the title")
        let measurement = XCTAttachment(string: "ring=\(ring), title=\(title), detail=\(detail), combinedMidY=\(title.union(detail).midY), delta=\(ring.midY - title.union(detail).midY)")
        measurement.name = "1752-\(name)-observed-geometry"
        measurement.lifetime = .keepAlways
        add(measurement)
        shot("1752-\(name)-summary")
    }

    @MainActor private func openPolishProfileItem(_ app: XCUIApplication) {
        open(app, element(app, "home-manage-profile"), ready: "home-profile-items", name: "profile-polish")
        expand(app, done: "home-sheet-done-profile")
        open(app, element(app, "home-profile-item-9a364c45-34fe-4f0a-93e6-fc507e2b0bdc"),
             ready: "home-profile-item-detail", name: "profile-item-polish")
        expand(app, done: "home-sheet-done-profile-item")
    }

    @MainActor private func assertCompactHomeSummary(_ app: XCUIApplication, workers: String, level: String) {
        for removed in ["home-context-activation", "context-segmented-bar", "home-manage-host",
                        "context-segment-instructions", "context-segment-profile", "context-segment-memory",
                        "context-segment-chapter", "context-segment-results", "context-segment-input"] {
            XCTAssertFalse(element(app, removed).exists, "Removed Home-only summary content: \(removed)")
        }
        let summary = element(app, "home-context-summary")
        XCTAssertTrue(summary.exists)
        for label in ["Read / Write", "Input", "Output", "Cost"] {
            XCTAssertFalse(summary.staticTexts[label].exists, "Home does not show the session's \(label) metric")
        }
        let pill = element(app, "home-manage-workers"), state = element(app, "home-manage-state")
        XCTAssertTrue(pill.exists)
        XCTAssertEqual(pill.label, workers)
        XCTAssertTrue((pill.value as? String)?.lowercased().contains(level.lowercased()) == true)
        XCTAssertGreaterThanOrEqual(pill.frame.minX, state.frame.maxX)
        XCTAssertEqual(pill.frame.midY, state.frame.midY, accuracy: 1)
        XCTAssertLessThanOrEqual(pill.frame.maxX, app.frame.maxX)
        let color = ink(app, pill)
        switch level {
        case "Normal": XCTAssertGreaterThan(color[1], color[0] + 0.1)
        case "Elevated":
            XCTAssertGreaterThan(color[0], color[2] + 0.15)
            XCTAssertGreaterThan(color[1], color[2] + 0.1)
        default:
            XCTAssertGreaterThan(color[0], color[1] + 0.2)
            XCTAssertGreaterThan(color[0], color[2] + 0.2)
        }
        let ring = element(app, "home-context-ring")
        XCTAssertTrue(ring.exists)
        XCTAssertEqual(ring.value as? String, "3 percent")
        XCTAssertEqual(ring.frame.width, ring.frame.height, accuracy: 0.5)
        let title = app.staticTexts["969K tokens left"]
        XCTAssertTrue(title.exists)
        XCTAssertLessThan(ring.frame.maxX, title.frame.minX)
        let detail = element(app, "home-context-detail").label.replacingOccurrences(of: "\u{00A0}", with: " ")
        XCTAssertTrue(detail.contains("31K/1M") && detail.contains("3% used"), detail)
        XCTAssertTrue(detail.contains("1.8M total tokens") && detail.contains("91.4% cache hit"), detail)
    }

    @MainActor func testProfileGroupsNotesByAreaWithoutBulkConfirmation() {
        let app = launchPolishManage(); defer { app.terminate() }
        open(app, element(app, "home-manage-profile"), ready: "home-profile-items", name: "profile-polish")
        expand(app, done: "home-sheet-done-profile")
        let areas = ["Communication", "Machines, devices & services", "Unsorted"].map { app.staticTexts[$0].firstMatch }
        for area in areas { XCTAssertTrue(area.exists, area.description) }
        XCTAssertLessThan(areas[0].frame.minY, areas[1].frame.minY, "Areas keep their order")
        XCTAssertLessThan(areas[1].frame.minY, areas[2].frame.minY, "Unsorted follows the reviewed areas")
        for kind in ["Preferences", "Standing decisions", "Delegation defaults", "Facts"] {
            XCTAssertFalse(app.staticTexts[kind].exists, "\(kind) is a note's kind, not its group")
        }
        XCTAssertFalse(element(app, "home-profile-confirm-all").exists, "No bulk confirmation")
        XCTAssertFalse(app.buttons["home-profile-confirm-all-button"].exists)
        let unsorted = element(app, "home-profile-item-9a364c45-34fe-4f0a-93e6-fc507e2b0bdc")
        XCTAssertTrue(unsorted.label.contains("inferred/needs-split") && unsorted.label.contains("Inferred"), unsorted.label)
        shot("profile-areas")
    }

    @MainActor func testRetireIconAndSubtextUseDestructiveInk() {
        let app = launchPolishManage(); defer { app.terminate() }
        openPolishProfileItem(app)
        let row = element(app, "home-profile-item-retire")
        let subtitle = element(app, "home-profile-item-retire-subtext")
        for color in [ink(app, row, leading: 44), ink(app, subtitle)] {
            XCTAssertGreaterThan(color[0], color[1] + 0.2)
            XCTAssertGreaterThan(color[0], color[2] + 0.2)
        }
        shot("1723-retire-destructive")
    }

    @MainActor func testTaskReadingSubtextLight() { exerciseTaskReadingSubtext("light", arguments: []) }
    @MainActor func testTaskReadingSubtextDark() { exerciseTaskReadingSubtext("dark", arguments: ["-home-dark"]) }
    @MainActor func testTaskReadingSubtextAccessibility() {
        exerciseTaskReadingSubtext("ax-large", arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
    }

    @MainActor private func exerciseTaskReadingSubtext(_ name: String, arguments: [String]) {
        let app = launchPolishManage(arguments + ["-home-task-padding-review"])
        defer { app.terminate() }
        let settings = element(app, "home-manage-settings")
        for _ in 0..<8 where !settings.isHittable { app.swipeUp() }
        let metadata = settings.staticTexts["Assistant profile and worker launch choices"]
        let settingsTitle = settings.staticTexts["Home Settings"]
        XCTAssertTrue(metadata.exists && settingsTitle.exists)
        let metadataLines = name == "ax-large" ? 2.0 : 1.0
        if name == "ax-large" {
            XCTAssertGreaterThan(metadata.frame.height, settingsTitle.frame.height, "The subtitle wraps at accessibility text")
        }
        let metadataHeight = metadata.frame.height / metadataLines
        XCTAssertGreaterThan(metadataHeight, 0)
        XCTAssertLessThan(metadataHeight, settingsTitle.frame.height,
                          "Default shared-row callers keep their smaller metadata style")
        shot("1771-default-metadata-\(name)")
        let tasks = element(app, "home-manage-tasks")
        for _ in 0..<8 where !tasks.isHittable { app.swipeDown() }
        open(app, tasks, ready: "home-task-terminal", name: "reading-subtext-tasks")
        expand(app, done: "home-sheet-done-tasks")
        let terminal = element(app, "home-task-terminal")
        for _ in 0..<8 where !terminal.isHittable { app.swipeUp() }
        open(app, terminal, ready: "home-task-detail", name: "reading-subtext-task")
        expand(app, done: "home-sheet-done-task")
        shot("1771-reading-header-\(name)")
        app.swipeUp()
        let title = element(app, "home-task-model-title")
        XCTAssertTrue(title.exists)
        let lineHeight = title.frame.height
        XCTAssertGreaterThan(lineHeight, 0)
        var geometry = ["metadataLine=\(metadataHeight)", "readingLine=\(lineHeight)",
                        app.staticTexts["fixture.home-typography"].label]
        for id in ["home-task-result", "home-task-model", "home-task-subagents", "home-task-spend"] {
            let value = element(app, "\(id)-subtext")
            XCTAssertTrue(value.exists)
            let lines = name == "ax-large" && id == "home-task-subagents" ? 2.0 : 1.0
            XCTAssertEqual(value.frame.height / lines, lineHeight, accuracy: 0.25,
                           "\(id) uses the approved reading size, not metadata")
            geometry.append("\(id): \(value.frame)")
        }
        let step = element(app, "home-task-checkin-summary-title")
        let done = element(app, "home-task-checkin-done-subtext")
        let next = element(app, "home-task-checkin-next-subtext")
        XCTAssertTrue(step.exists && done.exists && next.exists)
        let checkinHeight = step.frame.height + done.frame.height + next.frame.height
        XCTAssertGreaterThan(checkinHeight / lineHeight, 4.5,
                             "The long check-in wraps to at least five lines without the default two-line cap")
        XCTAssertTrue(element(app, "home-task-checkin-next").label.contains("report the remaining scope"),
                      "The complete check-in, including its final Next instruction, remains available")
        geometry.append("checkin step: \(step.frame) done: \(done.frame) next: \(next.frame) lines: \(checkinHeight / lineHeight)")
        let measurement = XCTAttachment(string: geometry.joined(separator: "\n"))
        measurement.name = "1771-reading-geometry-\(name)"
        measurement.lifetime = .keepAlways
        add(measurement)
        shot("1771-reading-worker-\(name)")
    }

    @MainActor func testWorkerRowsUseStandardSubtext() {
        let app = launchPolishManage(); defer { app.terminate() }
        open(app, element(app, "home-manage-tasks"), ready: "home-task-active", name: "tasks-polish")
        expand(app, done: "home-sheet-done-tasks")
        open(app, element(app, "home-task-active"), ready: "home-task-detail", name: "worker-polish")
        expand(app, done: "home-sheet-done-task")
        app.swipeUp()
        let reference = element(app, "home-task-model-title")
        XCTAssertTrue(reference.exists)
        let lineHeight = reference.frame.height
        XCTAssertGreaterThan(lineHeight, 0)
        for id in ["home-task-model", "home-task-subagents", "home-task-spend", "home-task-run-run-live"] {
            let value = element(app, "\(id)-subtext")
            XCTAssertTrue(value.exists)
            XCTAssertEqual(value.frame.height, lineHeight, accuracy: 0.25, "\(id) matches the approved subheadline reading size")
        }
        let done = element(app, "home-task-checkin-done-subtext")
        let next = element(app, "home-task-checkin-next-subtext")
        XCTAssertTrue(done.exists && next.exists)
        XCTAssertEqual(done.frame.height, lineHeight, accuracy: 0.25,
                       "Latest check-in Done uses the approved subheadline size of the single-line Worker values")
        XCTAssertEqual(next.frame.height, lineHeight, accuracy: 0.25,
                       "Latest check-in Next uses the approved subheadline size of the single-line Worker values")
        let measurement = XCTAttachment(string: "standardLine=\(lineHeight), latestCheckinDone=\(done.frame.height), next=\(next.frame.height)")
        measurement.name = "1723-worker-font-geometry"; measurement.lifetime = .keepAlways; add(measurement)
        shot("1723-worker-standard-subtext")
    }

    @MainActor func testTaskCardsKeepBalancedInsetsAndMemoryRowsIntact() {
        let app = launchPolishManage(["-home-task-padding-review"]); defer { app.terminate() }
        open(app, element(app, "home-manage-tasks"), ready: "home-task-active", name: "tasks-polish")
        expand(app, done: "home-sheet-done-tasks")
        for id in ["active", "terminal"] {
            let card = element(app, "home-task-card-\(id)-container")
            let title = element(app, "home-task-\(id)-title")
            let status = element(app, "home-task-\(id)-status")
            let footer = element(app, "home-task-\(id)-metadata")
            XCTAssertTrue(card.exists && title.exists && status.exists && footer.exists)
            let top = min(title.frame.minY, status.frame.minY) - card.frame.minY
            let bottom = card.frame.maxY - footer.frame.maxY
            XCTAssertEqual(top, bottom, accuracy: 0.5, "The painted card, not just its button's AX frame, has balanced insets")
        }
        shot("1723-tasks-balanced-light")
        app.buttons["home-sheet-done-tasks"].tap()
        open(app, element(app, "home-manage-memory-browser"), ready: "home-memory-row-39", name: "memory-polish")
        expand(app, done: "home-sheet-done-memory")
        let card = element(app, "home-memory-card-39-container")
        let title = element(app, "home-memory-row-39-title")
        let footer = element(app, "home-memory-row-39-metadata")
        XCTAssertTrue(card.exists && title.exists && footer.exists)
        XCTAssertEqual(title.frame.minY - card.frame.minY, card.frame.maxY - footer.frame.maxY, accuracy: 0.5,
                       "The shared row still hugs a Memory preview and its metadata")
        element(app, "home-memory-row-39").tap()
        XCTAssertTrue(element(app, "home-memory-detail").waitForExistence(timeout: 5), "Memory row navigation remains intact")
    }

    @MainActor func testChapterStatsBelongToBothSummaryHeaders() {
        let app = launchPolishManage(); defer { app.terminate() }
        open(app, element(app, "home-manage-chapters"), ready: "home-chapter-list", name: "chapters-polish")
        expand(app, done: "home-sheet-done-chapters")
        for ordinal in [2, 1] {
            open(app, element(app, "home-chapter-\(ordinal)"), ready: "home-chapter-detail", name: "chapter-polish")
            expand(app, done: "home-sheet-done-chapter")
            _ = assertChapterSummaryStats(app)
            shot("1723-chapter-\(ordinal)-stats-inside-header")
            app.buttons["home-sheet-done-chapter"].tap()
        }
    }

    @MainActor private func assertChapterSummaryStats(_ app: XCUIApplication) -> [XCUIElement] {
        let header = element(app, "home-chapter-header"), stats = element(app, "home-chapter-stats")
        XCTAssertTrue(stats.exists, "Active and sealed chapter counts belong to the summary, not a separate rows card")
        let tags = stats.staticTexts.allElementsBoundByIndex
        XCTAssertEqual(tags.count, 3)
        for phrase in ["user message", "Home repl", "task"] { XCTAssertTrue(tags.contains { $0.label.contains(phrase) }) }
        XCTAssertGreaterThanOrEqual(stats.frame.minY, element(app, "home-chapter-size").frame.maxY)
        XCTAssertLessThanOrEqual(stats.frame.maxY, header.frame.maxY)
        for tag in tags {
            XCTAssertGreaterThanOrEqual(tag.frame.minX, header.frame.minX)
            XCTAssertLessThanOrEqual(tag.frame.maxX, header.frame.maxX)
        }
        return tags
    }

    @MainActor func testSummaryAndChapterTagsFitAtXXXL() {
        let app = launchPolishManage(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"])
        defer { app.terminate() }
        assertCompactHomeSummary(app, workers: "0 workers", level: "Normal")
        let summary = element(app, "home-context-summary")
        for id in ["home-context-ring", "home-context-detail"] {
            XCTAssertTrue(summary.frame.contains(element(app, id).frame), "\(id) stays inside the compact summary at XXXL")
        }
        shot("1723-summary-xxxl")
        open(app, element(app, "home-manage-chapters"), ready: "home-chapter-list", name: "chapters-xxxl")
        expand(app, done: "home-sheet-done-chapters")
        open(app, element(app, "home-chapter-2"), ready: "home-chapter-detail", name: "chapter-xxxl")
        expand(app, done: "home-sheet-done-chapter")
        let tags = assertChapterSummaryStats(app)
        XCTAssertGreaterThan(Set(tags.map { $0.frame.minY.rounded() }).count, 1, "Tags wrap rather than clip at XXXL")
        shot("1723-chapter-xxxl-wrapping")
    }

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
        assertCompactHomeSummary(app, workers: workers.replacingOccurrences(of: " running", with: ""), level: level)
        keep("931-\(level)-manage")
    }

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
        let workers = element(app, "settings-row-model.queue_role_worker_")
        let tools = element(app, "settings-row-tools.active")
        XCTAssertTrue(workers.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(tools.exists, content.debugDescription)
        XCTAssertFalse(app.buttons["settings-section-model-open"].exists)
        XCTAssertFalse(app.buttons["settings-section-tools-open"].exists)
        XCTAssertFalse(app.buttons["settings-section-advanced-open"].exists)
        XCTAssertLessThan(workers.frame.minY, tools.frame.minY)
        XCTAssertEqual(workers.frame.minX, tools.frame.minX, accuracy: 1)
        XCTAssertEqual(workers.frame.width, tools.frame.width, accuracy: 1)
        shot("1478-home-settings-\(name)")
        shot("1478-home-settings-\(name)-bottom")
    }

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
            XCTAssertTrue(app.buttons["settings-section-tools-open"].waitForExistence(timeout: 8), app.debugDescription)
            XCTAssertFalse(app.buttons["settings-section-model-open"].exists, "Session Settings has no Models subsheet")
            let suffix = size.contains("Accessibility") ? "ax-large" : appearance
            shot("1478-session-settings-\(suffix)")
            groupCards(app, content)
            XCTAssertFalse(element(app, "settings-row-context.images.autoResize").exists, content.debugDescription)
            shot("1478-session-settings-\(suffix)-bottom")
            app.terminate()
        }
    }

    @MainActor private func groupCards(_ app: XCUIApplication, _ content: XCUIElement) {
        let compaction = app.buttons["settings-section-context-open"], more = app.buttons["settings-section-advanced-open"]
        let tools = app.buttons["settings-section-tools-open"]
        XCTAssertTrue(content.exists, app.debugDescription)
        XCTAssertFalse(app.staticTexts["Agent"].exists, app.debugDescription)
        XCTAssertFalse(app.staticTexts["Tools & Extensions"].exists, app.debugDescription)
        XCTAssertFalse(element(app, "settings-row-tools.active").exists, "Tools opens from its row")
        for row in [compaction, more, tools] { for _ in 0..<4 where !row.isHittable { app.swipeUp() } }
        XCTAssertTrue(compaction.exists && more.exists && tools.exists, app.debugDescription)
        for row in [more, tools] {
            XCTAssertEqual(row.frame.minX, compaction.frame.minX, accuracy: 1, "Rows share one card width")
            XCTAssertEqual(row.frame.width, compaction.frame.width, accuracy: 1, "Rows share one card width")
        }
        XCTAssertLessThan(compaction.frame.minY, tools.frame.minY, "Compaction precedes Tools")
        XCTAssertLessThan(tools.frame.minY, more.frame.minY, "Tools precedes More Settings")
    }

    @MainActor private func expandSheet(_ app: XCUIApplication, title text: String) {
        let title = app.navigationBars.staticTexts[text].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), app.debugDescription)
        var last = title.frame.minY
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.3)
            let now = title.frame.minY
            if abs(now - last) < 0.5 { break }
            last = now
        }
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
        keep("1214-memory")
        for _ in 0..<12 where !element(app, "home-memory-summary-0-16").exists { app.swipeUp() }
        XCTAssertTrue(element(app, "home-memory-summary-0-16").waitForExistence(timeout: 5))
        app.buttons["home-sheet-done-memory"].tap()
        open(app, element(app, "home-manage-tasks"), ready: "home-task-active", name: "tasks")
        expand(app, done: "home-sheet-done-tasks")
        keep("1214-tasks")
        app.terminate()
        app.launchArguments = ["-tron-session-configuration-fixture", "-fixture-appearance", "light"]
        app.launch()
        XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 10))
        app.buttons["Stop session"].tap()
        let history = app.buttons["Session History"]
        for _ in 0..<12 where !history.isHittable { app.swipeUp() }
        XCTAssertTrue(history.isHittable); history.tap()
        XCTAssertTrue(app.buttons["history-row-fixture-prompt"].waitForExistence(timeout: 10))
        let done = app.buttons.matching(NSPredicate(format: "label == 'Done'")).allElementsBoundByIndex.last(where: \.isHittable)!
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: 60, dy: done.frame.midY))
            .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: 60, dy: 20)))
        keep("1214-history")
    }

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
        let retry = app.buttons["feed-retry"]
        for _ in 0..<8 where !retry.exists { app.swipeUp() }
        XCTAssertTrue(retry.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(memoryRow.exists, "A failed page keeps the loaded rows")
        keep("1214-memory-page-error")
        retry.tap()
        XCTAssertTrue(app.buttons["home-memory-summary-0-16"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "home-memory-summary-0-16").count, 1)
        for _ in 0..<12 where !memoryRow.isHittable { app.swipeDown() }
        XCTAssertEqual(app.buttons.matching(identifier: "home-memory-row-39").count, 1, "Pages never duplicate rows")
        app.buttons["home-sheet-done-memory"].tap()

        open(app, element(app, "home-manage-tasks"), ready: "home-task-active", name: "tasks")
        expand(app, done: "home-sheet-done-tasks")
        XCTAssertEqual(app.buttons["home-task-active"].frame.width, memoryWidth, accuracy: 2, "Shared row layout has one content width")
        for _ in 0..<8 where !retry.exists { app.swipeUp() }
        XCTAssertTrue(retry.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["home-task-paged-19"].exists, "A failed page keeps the loaded rows")
        retry.tap()
        XCTAssertTrue(app.buttons["home-task-paged-20"].waitForExistence(timeout: 5))
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
        let after = reads(app)
        assertNoReads(app, since: after, "Returning to a task page does not refresh it")
        let last = app.buttons["home-task-paged-44"]
        for _ in 0..<8 where !last.exists { app.swipeUp() }
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "feed-end").waitForExistence(timeout: 5), "The last page is exhausted")
        XCTAssertEqual(app.buttons.matching(identifier: "home-task-paged-44").count, 1)
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

        XCTAssertFalse(element(app, "home-manage-context").exists, "Home Context is part of Manage Home")
        assertCompactHomeSummary(app, workers: "0 workers", level: "Normal")

        app.swipeUp()
        let settings = element(app, "home-manage-settings"), tasks = element(app, "home-manage-tasks")
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        XCTAssertFalse(element(app, "home-manage-permissions").exists)
        XCTAssertGreaterThan(settings.frame.minY, tasks.frame.maxY + 8, "Home Settings sits in a separate container")
        keep("01b-manage-bottom")
        app.swipeDown()

        let memoryRow = element(app, "home-manage-memory-browser"), window = app.windows.firstMatch
        for _ in 0..<3 where memoryRow.frame.maxY > window.frame.height - 60 {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
                .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
        }
        let rowTint = ink(app, memoryRow, leading: 56)
        let manageTint = ink(app, app.navigationBars.staticTexts["Manage Home"].firstMatch)

        open(app, element(app, "home-manage-memory-browser"), ready: "home-memory-row-39", name: "memory")
        expand(app, done: "home-sheet-done-memory")
        assertTitleTint(app, "Memory", matches: rowTint, and: manageTint)
        XCTAssertTrue(element(app, "home-memory-viewport").exists)
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

        open(app, element(app, "home-manage-chapters"), ready: "home-chapter-1", name: "chapters")
        expand(app, done: "home-sheet-done-chapters")
        assertTitleTint(app, "Chapters", matches: rowTint, and: manageTint)
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
        let topic = element(app, "home-chapter-topic-0")
        XCTAssertTrue(topic.label.hasSuffix("…"), topic.label)
        XCTAssertFalse(topic.label.contains("**"), topic.label)
        open(app, topic, ready: "home-reading-text", name: "topic")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'shared'")).firstMatch.exists, app.debugDescription)
        assertTitleTint(app, "Topic", matches: rowTint, and: manageTint)
        keep("06b-chapter-topic")
        closeTop(app)
        XCTAssertTrue(element(app, "home-chapter-detail").waitForExistence(timeout: 3))

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

        open(app, element(app, "home-manage-tasks"), ready: "home-task-active", name: "tasks")
        expand(app, done: "home-sheet-done-tasks")
        assertTitleTint(app, "Tasks", matches: rowTint, and: manageTint)
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
        let model = element(app, "home-task-model")
        XCTAssertTrue(model.label.contains("Model") && model.label.contains("Claude Opus 5.5"), model.label)
        let brief = element(app, "home-task-brief")
        XCTAssertTrue(brief.exists)
        XCTAssertFalse(app.buttons["Show all"].exists, "The brief never expands in place")
        let done = element(app, "home-task-checkin-done")
        let next = element(app, "home-task-checkin-next")
        XCTAssertTrue(done.exists && next.exists)
        XCTAssertTrue(done.label.contains("Gateway journey passed") && next.label.contains("Review native screenshots"),
                      [done.label, next.label].joined(separator: " | "))
        keep("09-task-detail")
        open(app, element(app, "home-task-brief-view-all"), ready: "home-reading-text", name: "brief")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'settings model doc'")).firstMatch.exists, "View All shows the whole brief")
        assertTitleTint(app, "Brief", matches: rowTint, and: manageTint)
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
        XCTAssertTrue(waitFor(stagedChips, count: 4, timeout: 5) && app.buttons["Remove resource, Wordcraft"].exists, app.debugDescription)
        app.buttons["Remove resource, Jev Decisions"].tap()
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

        for (index, selection) in ["Search memory", "Memory date", "Search memory"].enumerated() {
            let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", selection + ", Completed,")).firstMatch
            for _ in 0..<12 where !(chip.exists && chip.isHittable) {
                if selection == "Search memory" { app.swipeUp() } else { app.swipeDown() }
            }
            open(app, chip, ready: "home-tool-detail", name: "historical-\(index)")
            let outcome = element(app, "home-tool-outcome")
            XCTAssertTrue(outcome.label.hasSuffix(selection == "Memory date" ? "Found" : "2 matches"),
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
        toolSheet(app, "paged-zoom", chip: "Expand memory, Completed", index: 1, outcome: "Opened") {
            XCTAssertTrue(self.element(app, "home-tool-line-1122+2").exists)
        }
        toolSheet(app, "paged-task", chip: "Manage task, Completed", index: 2, outcome: "Running") {
            XCTAssertTrue(self.element(app, "home-tool-row-Check-in").label.contains("Gateway journey passed"))
        }
        for index in 0..<2 {
            for _ in 0..<8 { app.swipeDown() }
            let zooms = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Expand memory, Completed,'"))
            toolSheet(app, "paged-single-zoom-\(index)", chip: "Expand memory, Completed", index: zooms.count - 1, outcome: "Opened") {
                XCTAssertTrue(self.element(app, "home-tool-line-3539+0").exists)
            }
            for _ in 0..<8 { app.swipeDown() }
            let lists = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Manage task, Completed,'"))
            let list = lists.element(boundBy: lists.count - 1)
            for _ in 0..<12 where !(list.exists && list.isHittable) { app.swipeDown() }
            list.tap()
            XCTAssertTrue(app.buttons["Technical details"].waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(element(app, "home-tool-detail").exists,
                          "A historical catalog uses the task-list detail without needing a live origin")
            XCTAssertTrue(app.staticTexts["No tasks"].exists, app.debugDescription)
            keep("task-list-empty-historical-\(index)")
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

    @MainActor
    func testHomeToolDetailSheetsAndProfile() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-tool-transcript"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        XCTAssertTrue(waitFor(app.staticTexts["fixture.home-opened-session"], "label CONTAINS 'opened-session:home-session'"))

        toolSheet(app, "memory-search", chip: "Search memory, Completed", index: 0, outcome: "2 matches") {
            XCTAssertTrue(self.element(app, "home-tool-row-Range").label.contains("1100–1131"))
            self.assertReads(app, self.element(app, "home-tool-line-1110+0"), contains: "feat/890-sheets")
        }
        toolSheet(app, "date", chip: "Memory date, Completed", index: 0, outcome: "Found") {
            XCTAssertTrue(self.element(app, "home-tool-row-Date").label.contains("2026"))
            XCTAssertTrue(self.element(app, "home-tool-row-Time").exists)
        }
        toolSheet(app, "zoom-invalid", chip: "Expand memory, Completed", index: 0, outcome: "Not found") {
            XCTAssertTrue(self.allText(self.element(app, "home-tool-failure")).contains("No line 7+3"))
        }
        toolSheet(app, "zoom", chip: "Expand memory, Completed", index: 1, outcome: "Opened") {
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
            XCTAssertTrue(self.element(app, "home-tool-row-Layer").label.contains("Session"))
        }
        toolSheet(app, "settings-resolve", chip: "Settings, Completed", index: 1, outcome: "Read") {
            XCTAssertTrue(self.element(app, "home-tool-row-model.ref[role=worker]").label.contains("Claude Opus 5.5 · Session"))
        }
        toolSheet(app, "task-rejected", chip: "Manage task, Failed", index: 0, outcome: "Rejected") {
            let failure = self.allText(self.element(app, "home-tool-failure"))
            XCTAssertTrue(failure.contains("Rejected before it ran"), failure)
            XCTAssertTrue(failure.contains("root: must not have additional properties"), failure)
            XCTAssertFalse(failure.contains("Received arguments"), "The schema issues, not the raw arguments: \(failure)")
        }
        toolSheet(app, "task-steer", chip: "Manage task, Completed", index: 0, outcome: "Accepted") {
            XCTAssertTrue(self.allText(self.element(app, "home-tool-text-message")).contains("Profile"))
        }
        toolSheet(app, "task-report", chip: "Manage task, Completed", index: 1, outcome: "Final") {
            XCTAssertTrue(self.element(app, "home-tool-row-Page").label.contains("Bytes 0"))
            XCTAssertTrue(self.allText(self.element(app, "home-tool-text-report")).contains("PR #773"))
        }
        toolSheet(app, "task-status", chip: "Manage task, Completed", index: 2, outcome: "Running") {
            XCTAssertTrue(self.element(app, "home-tool-row-Check-in").label.contains("Gateway journey passed"))
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
            app.swipeUp()
            self.open(app, self.element(app, "home-tool-text-brief-view-all"), ready: "home-reading-text", name: "delegate-brief")
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Ask every decision'")).firstMatch.exists, "View All shows the whole brief")
            self.keep("tool-delegate-brief")
            self.closeTop(app)
        }

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
        open(app, profileRow, ready: "home-profile-items", name: "profile")
        expand(app, done: "home-sheet-done-profile")
        assertTitleTint(app, "Profile", matches: rowTint, and: manageTint)
        for area in ["Communication", "Machines, devices & services", "Unsorted"] { XCTAssertTrue(app.staticTexts[area].exists, area) }
        let item = element(app, "home-profile-item-9a364c45-34fe-4f0a-93e6-fc507e2b0bdc")
        XCTAssertTrue(item.label.contains("screenshots") && !item.label.contains("**"), item.label)
        XCTAssertTrue(item.label.contains("Inferred"), item.label)
        keep("profile-01-sheet")
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["No longer applied"].waitForExistence(timeout: 3))
        keep("profile-02-sheet-bottom")
        app.swipeDown()
        open(app, item, ready: "home-profile-item-detail", name: "profile-item")
        XCTAssertTrue(element(app, "home-profile-item-note-id").label.contains("9a364c45-34fe-4f0a-93e6-fc507e2b0bdc"))
        keep("profile-03-item")
    }

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
        open(app, element(app, "home-manage-profile"), ready: "home-profile-items", name: "profile")
        expand(app, done: "home-sheet-done-profile")

        let inferred = "9a364c45-34fe-4f0a-93e6-fc507e2b0bdc", confirmed = "6a26bfb7-f0d1-44ce-b0ae-9da01da3e55c"
        let rowActions = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'home-profile-confirm-'"))
        XCTAssertEqual(rowActions.count, 0, "Profile rows carry no inline Confirm")
        let inferredRow = element(app, "home-profile-item-\(inferred)")
        XCTAssertTrue(inferredRow.label.contains("Inferred"), inferredRow.label)
        XCTAssertTrue(element(app, "home-profile-item-\(confirmed)").label.contains("Confirmed by you"))
        let group = element(app, "home-profile-items")
        XCTAssertLessThan(abs(inferredRow.frame.width - group.frame.width), 2, "The row spans its group: \(inferredRow.frame) in \(group.frame)")
        XCTAssertFalse(element(app, "home-profile-confirm-all").exists, "Notes are confirmed one at a time")
        keep("profile-edit-00-list")

        open(app, inferredRow, ready: "home-profile-item-detail", name: "profile-item")
        expand(app, done: "home-sheet-done-profile-item")
        XCTAssertTrue(element(app, "home-profile-item-state").label.hasSuffix("Inferred"))
        element(app, "home-profile-item-confirm").tap()
        XCTAssertTrue(waitFor(element(app, "home-profile-item-state"), "label ENDSWITH 'Confirmed by you'"))
        XCTAssertTrue(element(app, "home-profile-last-change").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "home-profile-item-confirm").exists, "A confirmed item has nothing to confirm")
        keep("profile-edit-01-confirmed-undo")
        element(app, "home-profile-undo").tap()
        XCTAssertTrue(waitFor(element(app, "home-profile-item-state"), "label ENDSWITH 'Inferred'"))
        XCTAssertTrue(element(app, "home-profile-item-confirm").waitForExistence(timeout: 5))
        app.buttons["home-sheet-done-profile-item"].tap()
        XCTAssertTrue(waitFor(element(app, "home-profile-item-\(inferred)"), "label CONTAINS 'Inferred'"))

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
        XCTAssertTrue(waitFor(element(app, "home-profile-item-state"), "label ENDSWITH 'Confirmed by you'"))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'top wins: Chat > Home profile > Project > Mac.'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Edited: '")).firstMatch.exists)
        keep("profile-edit-05-edited")

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
        XCTAssertTrue(waitFor(element(app, "home-profile-item-state"), "label ENDSWITH 'Confirmed by you'"))
        app.buttons["home-sheet-done-profile-item"].tap()
        XCTAssertTrue(waitFor(element(app, "home-profile-item-\(decision)"), "label CONTAINS 'top wins'"))
        app.buttons["home-sheet-done-profile"].tap()

        app.buttons["home-sheet-done-manage"].tap()
        let gear = app.navigationBars.buttons["Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 8), app.debugDescription)
        gear.tap()
        let changes = app.buttons["Changes"].firstMatch
        XCTAssertTrue(changes.waitForExistence(timeout: 8))
        changes.tap()
        let entries = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'settings-change-' AND label CONTAINS 'Profile item'"))
        XCTAssertTrue(entries.firstMatch.waitForExistence(timeout: 8) && entries.firstMatch.label.contains("Changed by You"), app.debugDescription)
        let entry = entries.matching(NSPredicate(format: "label CONTAINS 'Changed by Home'")).firstMatch
        for _ in 0..<8 where !entry.isHittable { app.swipeUp() }; XCTAssertTrue(entry.label.contains("Inferred preference"), entry.label)
        keep("profile-edit-08-changes")
        entry.tap()
        XCTAssertTrue(app.buttons["Undo"].firstMatch.waitForExistence(timeout: 5))
        keep("profile-edit-09-change-detail")
    }

    @MainActor private func toolSheet(_ app: XCUIApplication, _ name: String, chip label: String, index: Int, outcome: String,
                                      _ checks: () -> Void) {
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

    @MainActor private func allText(_ element: XCUIElement) -> String {
        XCTAssertTrue(element.waitForExistence(timeout: 3), element.debugDescription)
        return ([element.label] + element.descendants(matching: .any).allElementsBoundByIndex.map(\.label)).joined(separator: " ")
    }

    @MainActor private func assertMarkdown(_ element: XCUIElement, contains text: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 3), text)
        let rendered = element.descendants(matching: .staticText).allElementsBoundByIndex.map(\.label)
            .contains { $0.contains(text) && !$0.contains("**") && !$0.contains("`") }
        XCTAssertTrue(rendered, "Markdown renders: \(allText(element))")
    }

    @MainActor private func assertReads(_ app: XCUIApplication, _ line: XCUIElement, contains text: String) {
        XCTAssertTrue(line.waitForExistence(timeout: 3), text)
        XCTAssertFalse(line.label.contains("**"), line.label)
        open(app, line, ready: "home-reading-text", name: "line")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists, app.debugDescription)
        closeTop(app)
        XCTAssertTrue(element(app, "home-tool-detail").waitForExistence(timeout: 3))
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @MainActor private func open(_ app: XCUIApplication, _ row: XCUIElement, ready: String, name: String) {
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(name)\n\(app.debugDescription)")
        let started = Date()
        row.tap()
        XCTAssertTrue(element(app, ready).waitForExistence(timeout: 8), "\(ready)\n\(app.debugDescription)")
        timings[name] = (Date().timeIntervalSince(started) * 1000).rounded()
    }

    @MainActor private func reads(_ app: XCUIApplication) -> String {
        app.staticTexts["fixture.home-read-counts"].label
    }

    @MainActor private func assertNoReads(_ app: XCUIApplication, since baseline: String, _ message: String) {
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", baseline),
                                                object: app.staticTexts["fixture.home-read-counts"])
        changed.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 1.5), .completed, "\(message): \(reads(app))")
    }

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

    @MainActor private func closeTop(_ app: XCUIApplication) {
        let done = app.buttons.matching(NSPredicate(format: "label == 'Done'")).allElementsBoundByIndex.last(where: \.isHittable)
        XCTAssertNotNil(done, app.debugDescription)
        done?.tap()
    }

    @MainActor private func assertTitleTint(_ app: XCUIApplication, _ title: String, matches row: [Double], and manage: [Double]) {
        let tint = ink(app, app.navigationBars.staticTexts[title].firstMatch)
        let distance = { (a: [Double], b: [Double]) in zip(a, b).map { abs($0 - $1) }.max() ?? 1 }
        XCTAssertLessThan(distance(tint, row), 0.12, "\(title)'s title takes its Manage Home row's tint: \(tint) vs \(row)")
        XCTAssertLessThan(distance(tint, manage), 0.12, "\(title)'s title is Manage Home's emerald sheet theme: \(tint) vs \(manage)")
    }

    @MainActor private func keep(_ name: String) {
        XCTAssertFalse(XCUIApplication().images["chevron.right"].exists, "\(name): Manage Home rows carry no trailing chevron")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
