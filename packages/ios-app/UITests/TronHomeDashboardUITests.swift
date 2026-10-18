import XCTest

/// The Home dashboard view (#973) on the hosted Home fixture: the usage card,
/// Home's running and recently completed workers, ordinary read/unread sessions,
/// the shared View All sheet, and the floating Home button above the
/// dashboard logo. Screenshots are kept as attachments.
final class TronHomeDashboardUITests: XCTestCase {
    /// A worker Home dispatches while the view is open appears in In Progress
    /// as soon as its catalog row arrives, without relaunching.
    @MainActor
    func testNewWorkerAppearsWithoutRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-dashboard-workers", "-dashboard-view-home", "-home-dashboard-new-worker"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["session-row-home-shell-fixture:worker-new"].waitForExistence(timeout: 10), app.debugDescription)
        // Worker identity rides on the synced catalog rows: the view never queries Home's task ledger.
        XCTAssertEqual(app.staticTexts["fixture.home-task-list-reads"].label, "task-list-reads:0")
    }

    /// #982: the view's sections fade in once, in stagger order, while the usage
    /// card holds the shared pulse at its final height; its rows then fade in
    /// without a layout jump, and a live new worker re-fades nothing.
    @MainActor
    func testSectionsRevealInOrderAndLiveUpdatesDoNotRefade() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-dashboard-workers", "-dashboard-view-home",
                               "-home-dashboard-usage-delay", "-home-dashboard-new-worker", "-home-dashboard-new-worker-late"]
        app.launch(); defer { app.terminate() }

        let card = element(app, "home-usage-card")
        let reveals = app.staticTexts["fixture.dashboard-reveals"]
        XCTAssertTrue(card.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(waitFor(card, "label == 'Loading account usage'"), card.label)
        // The card (order 0), In Progress (1) and Recently Completed (2) reveal
        // while the card still shows its pulse.
        XCTAssertTrue(waitFor(reveals, "label BEGINSWITH 'orders:0,1,2'"), reveals.label)
        XCTAssertEqual(card.label, "Loading account usage", "The usage read is still in flight")
        let inProgress = app.staticTexts["In Progress"], completed = app.staticTexts["Recently Completed"]
        XCTAssertTrue(inProgress.exists && completed.exists, app.debugDescription)
        XCTAssertLessThan(card.frame.maxY, inProgress.frame.minY)
        XCTAssertLessThan(inProgress.frame.minY, completed.frame.minY)
        let loadingHeight = card.frame.height
        keep("05-usage-loading")

        // Loader to content at the same height.
        XCTAssertTrue(waitFor(card, "label BEGINSWITH 'Anthropic, 42%'"), card.label)
        XCTAssertEqual(card.frame.height, loadingHeight, accuracy: 1, "The card keeps its height when usage arrives")
        let settled = reveals.label
        keep("06-usage-content")

        // A live catalog update inserts its row without re-revealing anything.
        let newWorker = app.buttons["session-row-home-shell-fixture:worker-new"]
        XCTAssertFalse(newWorker.exists)
        XCTAssertTrue(newWorker.waitForExistence(timeout: 10), app.debugDescription)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(reveals.label, settled, "Refreshes never re-fade existing content")
        XCTAssertTrue(card.label.hasPrefix("Anthropic, 42%"), "Refreshes keep the usage content")
    }

    /// Tapping the usage card opens the Filter-style providers sheet; a hidden
    /// provider leaves the card and returns when shown again, and with every
    /// provider hidden the card keeps a compact row that reopens the sheet.
    @MainActor
    func testUsageCardChoosesItsProviders() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-dashboard-workers", "-dashboard-view-home"]
        app.launch(); defer { app.terminate() }

        let card = element(app, "home-usage-card")
        XCTAssertTrue(card.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(waitFor(card, "label CONTAINS 'Anthropic, ' AND label CONTAINS 'OpenAI Codex, '"), card.label)
        card.tap()
        let anthropic = app.buttons["home-usage-provider-anthropic"], codex = app.buttons["home-usage-provider-openai-codex"]
        XCTAssertTrue(anthropic.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.navigationBars["Usage Providers"].exists || app.staticTexts["Usage Providers"].exists, app.debugDescription)
        // Only providers with usage support are listed.
        XCTAssertFalse(app.buttons["home-usage-provider-fixture"].exists)
        XCTAssertEqual(anthropic.value as? String, "Selected")
        keep("07-usage-providers-sheet")

        anthropic.tap()
        XCTAssertTrue(waitFor(anthropic, "value == 'Not selected'"), app.debugDescription)
        XCTAssertTrue(waitFor(card, "NOT (label CONTAINS 'Anthropic') AND label CONTAINS 'OpenAI Codex, '"), card.label)
        codex.tap()
        XCTAssertTrue(waitFor(card, "label == 'Usage, no providers shown'"), card.label)
        app.buttons["Done"].tap()
        XCTAssertTrue(waitFor(anthropic, "exists == false"), app.debugDescription)
        keep("08-usage-card-all-hidden")

        // The compact row reopens the sheet; showing a provider restores it.
        card.tap()
        XCTAssertTrue(anthropic.waitForExistence(timeout: 5), app.debugDescription)
        anthropic.tap()
        XCTAssertTrue(waitFor(card, "label BEGINSWITH 'Anthropic, ' AND NOT (label CONTAINS 'OpenAI Codex')"), card.label)
        codex.tap()
        XCTAssertTrue(waitFor(card, "label CONTAINS 'Anthropic, ' AND label CONTAINS 'OpenAI Codex, '"), card.label)
    }

    /// Full AppModel/catalog socket path: View All must include continuation
    /// pages, preserve attention, search ordinary titles and open the exact row.
    @MainActor
    func testOtherSessionsAllPagesSearchAndReadNavigation() {
        continueAfterFailure = false
        let app = otherSessionsApp()
        app.launch(); defer { app.terminate() }
        openOtherSessions(app)
        let reads = app.staticTexts["fixture.dashboard-catalog-reads"]
        XCTAssertFalse(app.buttons["home-other-sessions-sheet-row-home-shell-fixture:renamed-task"].exists)
        app.buttons["home-other-sessions-sheet-search"].tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        if app.buttons["Continue"].exists { app.buttons["Continue"].tap() }
        field.typeText("Home")
        let namedHome = app.buttons["home-other-sessions-sheet-row-home-shell-fixture:chat-read"]
        XCTAssertTrue(namedHome.waitForExistence(timeout: 5), "An ordinary chat called Home is not a chapter")
        XCTAssertFalse(app.buttons["home-other-sessions-sheet-row-home-shell-fixture:worker-running"].exists)
        replace(field, with: "Vacation", app: app)
        XCTAssertTrue(noMatches(app).waitForExistence(timeout: 5), "Renaming a worker cannot turn it into an ordinary session")
        replace(field, with: "Apple Watch", app: app)
        let oldest = app.buttons["home-other-sessions-sheet-row-home-shell-fixture:chat-unread"]
        XCTAssertTrue(oldest.waitForExistence(timeout: 5), "The last catalog page must be searchable in View All")
        XCTAssertTrue(oldest.label.contains("unread"), oldest.label)
        keep("1310-all-pages-search")
        oldest.tap()
        XCTAssertTrue(app.textViews["Message input"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(waitFor(app.staticTexts["fixture.home-opened-session"], "label == 'opened-session:chat-unread'"))
        XCTAssertTrue(app.staticTexts["fixture.home-diagnostics"].label.contains("selected-profile=Optional(\"home-shell-fixture\")"))
        XCTAssertTrue(waitFor(reads, "label CONTAINS 'reads:chat-unread:1'"), reads.label)
        app.buttons["Back"].tap()
        openOtherSessions(app)
        app.buttons["home-other-sessions-sheet-search"].tap()
        let reopenedField = app.textFields.firstMatch
        XCTAssertTrue(reopenedField.waitForExistence(timeout: 5))
        reopenedField.typeText("Apple Watch")
        XCTAssertTrue(oldest.waitForExistence(timeout: 5))
        XCTAssertFalse(oldest.label.contains("unread"), "Reading keeps an ordinary session in Other Sessions")
        keep("1310-read-session-retained")
    }

    /// A mounted View All is a live child of the catalog, not a frozen copy.
    @MainActor
    func testOtherSessionsSheetPublishesLiveRenameAndEmptyProjection() {
        continueAfterFailure = false
        for empty in [false, true] {
            let app = otherSessionsApp(extra: ["-home-dashboard-live-change"] + (empty ? ["-home-dashboard-live-empty"] : []))
            app.launch(); defer { app.terminate() }
            openOtherSessions(app)
            let row = app.buttons["home-other-sessions-sheet-row-home-shell-fixture:chat-read"]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            XCTAssertTrue(row.label.hasPrefix("Home,"), row.label)
            if empty {
                XCTAssertTrue(waitFor(row, "exists == false", timeout: 25), app.debugDescription)
                XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'No sessions'")).firstMatch.exists,
                              "An emptied sheet must explain the empty projection")
            } else {
                XCTAssertTrue(waitFor(row, "label BEGINSWITH 'Renamed ordinary chat,'", timeout: 25), app.debugDescription)
            }
            keep("1310-live-\(empty ? "empty" : "rename")")
            app.buttons["Done"].tap()
            if empty {
                XCTAssertTrue(waitFor(app.staticTexts["Other Sessions"], "exists == false"))
                XCTAssertFalse(element(app, "home-other-sessions-view-all").exists)
            }
            app.terminate()
        }
    }

    @MainActor
    func testOtherSessionsEmptyAndServerSelectionPreserveWorkers() {
        continueAfterFailure = false
        let app = otherSessionsApp(extra: ["-home-dashboard-empty"])
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["session-row-home-shell-fixture:worker-running"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Other Sessions"].exists)
        XCTAssertFalse(element(app, "home-other-sessions-view-all").exists)
        XCTAssertTrue(app.buttons["home-floating-button"].exists)
        app.buttons["dashboard.menu"].tap()
        app.buttons["Filter"].tap()
        let other = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Home fixture'")).firstMatch
        for _ in 0..<3 where !other.isHittable { app.swipeUp() }
        XCTAssertTrue(other.isHittable, app.debugDescription)
        other.tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(waitFor(app.buttons["session-row-home-shell-fixture:worker-running"], "exists == false"))
        XCTAssertFalse(app.staticTexts["Other Sessions"].exists)
        keep("1310-empty-server-selection")
    }

    /// Identical session IDs on two Macs must route/read the row's owning Mac,
    /// not whichever connection happened to be focused when the sheet opened.
    @MainActor
    func testOtherSessionsPreviewRoutesToOwningServer() {
        continueAfterFailure = false
        let app = otherSessionsApp(extra: ["-home-dashboard-secondary"])
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-floating-button"].waitForExistence(timeout: 10))
        app.buttons["dashboard.menu"].tap()
        app.buttons["Filter"].tap()
        let homeSource = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Home fixture'")).firstMatch
        for _ in 0..<3 where !homeSource.isHittable { app.swipeUp() }
        XCTAssertTrue(homeSource.isHittable, app.debugDescription)
        homeSource.tap() // Leave only Other Mac selected.
        app.buttons["Done"].tap()
        let row = app.buttons["session-row-competing-profile:chat-recent-unread"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["session-row-home-shell-fixture:chat-recent-unread"].exists)
        XCTAssertFalse(element(app, "home-other-sessions-view-all").exists, "One eligible row needs no View All")
        XCTAssertTrue(row.label.contains("unread"))
        row.tap()
        XCTAssertTrue(app.textViews["Message input"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(waitFor(app.staticTexts["fixture.home-diagnostics"], "label CONTAINS 'selected-profile=Optional(\"competing-profile\")'"))
        XCTAssertTrue(waitFor(app.staticTexts["fixture.home-opened-session"], "label == 'opened-session:chat-recent-unread'"))
        XCTAssertTrue(waitFor(app.staticTexts["fixture.dashboard-catalog-reads"], "label CONTAINS 'chat-recent-unread:1'"))
        keep("1310-profile-qualified-preview-open")
    }

    @MainActor private func otherSessionsApp(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-dashboard-workers",
                               "-dashboard-view-home", "-home-dashboard-other-sessions", "-home-dashboard-behavior"] + extra
        return app
    }

    @MainActor private func openOtherSessions(_ app: XCUIApplication) {
        let viewAll = element(app, "home-other-sessions-view-all")
        XCTAssertTrue(app.buttons["home-floating-button"].waitForExistence(timeout: 10))
        for _ in 0..<5 where !viewAll.isHittable { app.swipeUp() }
        XCTAssertTrue(viewAll.isHittable, app.debugDescription)
        viewAll.tap()
        XCTAssertTrue(app.buttons["home-other-sessions-sheet-row-home-shell-fixture:chat-active"].waitForExistence(timeout: 5))
    }

    /// Visual approval pass: the production dashboard and existing View All
    /// sheet, with mixed activity/attention and misleading ordinary titles.
    /// Navigation and Gateway boundary validation live in the focused journeys above.
    @MainActor
    func testOtherSessionsPreviewInLightAndDark() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-dashboard-workers",
                                   "-dashboard-view-home", "-home-dashboard-other-sessions"]
                + (appearance == "dark" ? ["-home-dark"] : [])
            app.launch()
            XCTAssertTrue(element(app, "home-usage-card").waitForExistence(timeout: 30), app.debugDescription)
            XCTAssertTrue(app.buttons["session-row-home-shell-fixture:worker-running"].waitForExistence(timeout: 10))
            XCTAssertEqual(app.buttons["home-floating-button"].value as? String, "Ready")
            XCTAssertFalse(app.buttons["home-pinned-row"].exists)
            XCTAssertFalse(element(app, "home-in-progress-view-all").exists)
            keep("other-sessions-\(appearance)-dashboard-top")

            let viewAll = element(app, "home-other-sessions-view-all")
            let fifth = app.buttons["session-row-home-shell-fixture:chat-finance"]
            for _ in 0..<5 where !(fifth.exists && fifth.isHittable && viewAll.exists && viewAll.isHittable) { app.swipeUp() }
            XCTAssertTrue(viewAll.isHittable, app.debugDescription)
            assertHeaderAction(viewAll, title: app.staticTexts["Other Sessions"], app: app)
            let ids = ["chat-active", "chat-read", "chat-recent-unread", "chat-worker-title", "chat-finance", "chat-older", "chat-unread", "ordinary-session"]
            XCTAssertEqual(ids.filter { app.buttons["session-row-home-shell-fixture:\($0)"].exists }, Array(ids.prefix(5)))
            XCTAssertFalse(app.staticTexts["Unread"].exists)
            keep("other-sessions-\(appearance)-dashboard-bottom")

            viewAll.tap()
            let first = app.buttons["home-other-sessions-sheet-row-home-shell-fixture:chat-active"]
            XCTAssertTrue(first.waitForExistence(timeout: 5), app.debugDescription)
            keep("other-sessions-\(appearance)-sheet-medium")
            first.swipeUp()
            XCTAssertTrue(app.buttons["home-other-sessions-sheet-row-home-shell-fixture:chat-older"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["home-other-sessions-sheet-row-home-shell-fixture:renamed-task"].exists)
            keep("other-sessions-\(appearance)-sheet-after-swipe")
            app.terminate()
        }
    }

    /// #1003: each usage window is its own right-aligned column, its copy with
    /// a bar about a quarter of the card wide directly beneath it; two windows
    /// sit side by side, and the provider name is vertically centered against
    /// them. A long name keeps clear of its column.
    @MainActor
    func testUsageCardRowsShowWindowColumns() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-dashboard-workers", "-dashboard-view-home",
                               "-home-usage-long-name"]
        app.launch(); defer { app.terminate() }

        let card = element(app, "home-usage-card")
        XCTAssertTrue(card.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(waitFor(card, "label CONTAINS 'Anthropic (CortexKit), 48% used (Weekly)'"), card.label)
        XCTAssertTrue(card.label.hasPrefix("Anthropic, 42% used (5h) · 18% used (Weekly)"), card.label)
        let probe = app.staticTexts["fixture.home-usage-layout"]
        XCTAssertTrue(waitFor(probe, "label CONTAINS 'cortexkit.column0.bar='"), probe.label)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        var frames: [String: CGRect] = [:]
        for entry in probe.label.split(separator: ";") {
            let pair = entry.split(separator: "=")
            let v = pair[1].split(separator: ",").compactMap { Double($0) }
            frames[String(pair[0])] = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
        }
        let cardFrame = try! XCTUnwrap(frames["card"])
        for (provider, columns) in [("anthropic", 2), ("openai-codex", 2), ("cortexkit", 1)] {
            let name = try! XCTUnwrap(frames["\(provider).name"], probe.label)
            XCTAssertNil(frames["\(provider).column\(columns)"], "\(provider) has \(columns) column(s)")
            var previous: CGRect?
            for index in 0..<columns {
                let column = try! XCTUnwrap(frames["\(provider).column\(index)"], probe.label)
                let bar = try! XCTUnwrap(frames["\(provider).column\(index).bar"], probe.label)
                XCTAssertEqual(bar.width, column.width, accuracy: 1, "\(provider) bar spans its own column")
                XCTAssertEqual(bar.minX, column.minX, accuracy: 1)
                XCTAssertEqual(bar.maxY, column.maxY, accuracy: 1, "\(provider) bar sits under its copy")
                XCTAssertEqual(bar.height, 5, accuracy: 0.5)
                // Every non-zero fill keeps the capsule's rounded left end: it
                // starts at the track's start and is never narrower than tall.
                let fill = try! XCTUnwrap(frames["\(provider).column\(index).fill"], probe.label)
                XCTAssertEqual(fill.minX, bar.minX, accuracy: 0.5, "\(provider) fill starts at its track")
                XCTAssertEqual(fill.height, bar.height, accuracy: 0.5)
                XCTAssertGreaterThanOrEqual(fill.width + 0.01, fill.height, "\(provider) fill keeps its rounded ends")
                XCTAssertGreaterThan(bar.width / cardFrame.width, 0.2, "\(provider) bar is about a quarter of the card")
                XCTAssertLessThan(bar.width / cardFrame.width, 0.34, "\(provider) bar no longer spans the card")
                XCTAssertEqual(column.midY, name.midY, accuracy: 1, "\(provider) name is centered against its columns")
                XCTAssertGreaterThan(column.minX, name.maxX, "\(provider) name keeps clear of its columns")
                if let previous {
                    XCTAssertGreaterThan(column.minX, previous.maxX, "windows sit side by side")
                    XCTAssertEqual(column.minY, previous.minY, accuracy: 0.5)
                }
                previous = column
            }
            XCTAssertEqual(previous!.maxX, cardFrame.maxX - 12, accuracy: 1, "\(provider) columns are right-aligned")
        }
        // OpenAI's weekly window is 2% used: proportionally under 2pt, its fill
        // is a round dot exactly one bar height wide, while a larger share
        // (Anthropic's 42%) stays proportional.
        let small = try! XCTUnwrap(frames["openai-codex.column1.fill"], probe.label)
        let smallTrack = try! XCTUnwrap(frames["openai-codex.column1.bar"], probe.label)
        XCTAssertLessThan(smallTrack.width * 0.02, small.height, "the fixture share is below one bar height")
        XCTAssertEqual(small.width, small.height, accuracy: 0.5, "a small share is a round dot")
        let large = try! XCTUnwrap(frames["anthropic.column0.fill"], probe.label)
        let largeTrack = try! XCTUnwrap(frames["anthropic.column0.bar"], probe.label)
        XCTAssertEqual(large.width, largeTrack.width * 0.42, accuracy: 1, "a larger share stays proportional")
        keep("11-usage-card-window-columns")
    }

    /// #1163: every plan window a provider enforces reaches its compact
    /// surfaces. OpenCode Go's monthly limit is its third window: the card
    /// keeps all three columns on the name's line, and a window warns from 60%
    /// and shows its reached limit on the card, the Providers row and its
    /// detail sheet.
    @MainActor
    func testUsageShowsMonthlyWindowAndExhaustedLimit() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-dashboard-workers", "-dashboard-view-home",
                               "-home-usage-opencode-go"]
        app.launch(); defer { app.terminate() }

        let card = element(app, "home-usage-card")
        XCTAssertTrue(card.waitForExistence(timeout: 30), app.debugDescription)
        let line = "0% used (5h) · 72% used (Weekly) · 100% used (Monthly)"
        XCTAssertTrue(waitFor(card, "label CONTAINS 'Opencode Go, \(line)'"), card.label)
        XCTAssertTrue(card.label.hasPrefix("Anthropic, 42% used (5h) · 18% used (Weekly)"), "two-window rows are unchanged: \(card.label)")
        let probe = app.staticTexts["fixture.home-usage-layout"]
        XCTAssertTrue(waitFor(probe, "label CONTAINS 'opencode-go.column2.exhausted='"), probe.label)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        var frames: [String: CGRect] = [:]
        for entry in probe.label.split(separator: ";") {
            let pair = entry.split(separator: "=")
            let v = pair[1].split(separator: ",").compactMap { Double($0) }
            frames[String(pair[0])] = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
        }
        let name = try! XCTUnwrap(frames["opencode-go.name"], probe.label)
        var previous = name
        for index in 0..<3 {
            let column = try! XCTUnwrap(frames["opencode-go.column\(index)"], probe.label)
            XCTAssertEqual(column.midY, name.midY, accuracy: 1, "column \(index) shares the name's line")
            XCTAssertGreaterThan(column.minX, previous.maxX, "column \(index) sits clear of what precedes it")
            previous = column
        }
        // Each level draws its own accent: 5h at 0% stays the usage accent,
        // weekly at 72% warns, and the monthly limit is reached with a full bar.
        XCTAssertNil(frames["opencode-go.column0.warning"] ?? frames["opencode-go.column0.exhausted"], probe.label)
        XCTAssertNotNil(frames["opencode-go.column1.warning"], probe.label)
        let monthly = try! XCTUnwrap(frames["opencode-go.column2.bar"], probe.label)
        XCTAssertEqual(try! XCTUnwrap(frames["opencode-go.column2.fill"]).width, monthly.width, accuracy: 0.5)
        XCTAssertNil(frames["anthropic.column0.warning"] ?? frames["anthropic.column1.warning"], "under 60% never warns")
        keep("12-usage-card-monthly-exhausted")

        app.buttons["dashboard.menu"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["Settings"].tap()
        let providers = app.buttons["settings-link-Model Providers"]
        XCTAssertTrue(providers.waitForExistence(timeout: 10), app.debugDescription)
        providers.tap()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Account usage: \(line)")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        keep("13-providers-row-monthly-exhausted")
        app.buttons["Details for Opencode Go"].tap()
        XCTAssertTrue(app.staticTexts["Monthly"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["100% used"].exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Resets '")).count >= 3, app.debugDescription)
        keep("14-provider-detail-monthly-exhausted")
    }

    /// #1009: the Recently Completed sheet's floating search button opens the
    /// shared search pill, which filters the rows by title locally: tolerant
    /// of diacritics and abbreviations, a title prefix ranked above a match
    /// inside a word, and the shared placeholder when nothing matches.
    @MainActor
    func testRecentlyCompletedSheetSearchesTitles() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-dashboard-workers", "-dashboard-view-home"]
        app.launch(); defer { app.terminate() }

        XCTAssertTrue(app.buttons["session-row-home-shell-fixture:worker-running"].waitForExistence(timeout: 10), app.debugDescription)
        app.swipeUp()
        let viewAll = element(app, "home-completed-view-all")
        XCTAssertTrue(viewAll.waitForExistence(timeout: 5), app.debugDescription)
        assertHeaderAction(viewAll, title: app.staticTexts["Recently Completed"], app: app)
        XCTAssertTrue(app.buttons["session-row-home-shell-fixture:worker-unread-1"].exists,
                      "Explicitly unread workers stay in Recently Completed")
        viewAll.tap()
        let row = { (id: String) in app.buttons["home-completed-sheet-row-home-shell-fixture:\(id)"] }
        XCTAssertTrue(row("worker-done-1").waitForExistence(timeout: 5), app.debugDescription)

        let searchButton = app.buttons["home-completed-sheet-search"]
        XCTAssertTrue(searchButton.exists, app.debugDescription)
        XCTAssertGreaterThan(searchButton.frame.minX, app.frame.width * 0.7, "the search button sits bottom right")
        XCTAssertGreaterThan(searchButton.frame.minY, app.frame.height * 0.5, "the search button sits bottom right")
        keep("12-recently-completed-search-button")
        searchButton.tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.buttons["Close search"].exists)
        XCTAssertFalse(searchButton.exists, "the pill replaces the button")

        // Abbreviation across words: "simlan" finds "Simulator lane cleanup".
        field.typeText("simlan")
        XCTAssertTrue(row("worker-done-7").waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(waitFor(row("worker-done-1"), "exists == false"), app.debugDescription)
        XCTAssertFalse(row("worker-done-2").exists)
        keep("13-recently-completed-search-filtered")

        // Diacritics and case fold; every word must match.
        replace(field, with: "GÀRDEN email", app: app)
        XCTAssertTrue(row("worker-done-2").waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(waitFor(row("worker-done-7"), "exists == false"), app.debugDescription)
        replace(field, with: "garden budget", app: app)
        XCTAssertTrue(noMatches(app).waitForExistence(timeout: 3), app.debugDescription)

        // "ra": the title starting with it ranks above the older-ordered title
        // that only contains it ("Garden review email dRAft").
        replace(field, with: "ra", app: app)
        let raindrop = row("worker-done-6"), garden = row("worker-done-2")
        XCTAssertTrue(raindrop.waitForExistence(timeout: 3) && garden.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertLessThan(raindrop.frame.minY, garden.frame.minY, "a title prefix ranks above a match inside a word")
        XCTAssertFalse(row("worker-done-3").exists, "Kitchen countertop bids has no 'ra'")

        app.buttons["Close search"].tap()
        XCTAssertTrue(row("worker-done-1").waitForExistence(timeout: 3), "closing search restores every row")
        XCTAssertTrue(app.buttons["home-completed-sheet-search"].waitForExistence(timeout: 3))
    }

    /// #1009: dashboard search lists the dashboard's own session rows, ranked
    /// by title on the iPhone; it has no remote-ranking options button and no
    /// "Open matching session" action rows, and it searches every session the
    /// server filter shows, not only Home's sections.
    @MainActor
    func testDashboardSearchListsPlainSessionRows() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-dashboard-workers", "-dashboard-view-home"]
        app.launch(); defer { app.terminate() }

        XCTAssertTrue(app.buttons["session-row-home-shell-fixture:worker-running"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["dashboard.menu"].tap()
        app.buttons["Search"].tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.buttons["Close search"].exists)
        XCTAssertFalse(app.buttons["Search options"].exists, "no remote-ranking options button")

        // The simulator's one-time swipe-typing tip covers the keyboard.
        if app.buttons["Continue"].exists { app.buttons["Continue"].tap() }
        field.typeText("dedup")
        let dedupe = app.buttons["session-row-home-shell-fixture:worker-unread-3"]
        XCTAssertTrue(dedupe.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(waitFor(app.buttons["session-row-home-shell-fixture:worker-running"], "exists == false"), app.debugDescription)
        XCTAssertFalse(app.staticTexts["Open matching session"].exists)
        XCTAssertFalse(app.staticTexts["Searching connected Gateways…"].exists)
        XCTAssertFalse(element(app, "home-usage-card").exists, "results replace the Home sections")
        keep("14-dashboard-search-results")

        // Search includes ordinary chats as well as workers.
        replace(field, with: "ordinary", app: app)
        XCTAssertTrue(app.buttons["session-row-home-shell-fixture:ordinary-session"].waitForExistence(timeout: 3), app.debugDescription)
        replace(field, with: "qqqzzz", app: app)
        XCTAssertTrue(noMatches(app).waitForExistence(timeout: 3), app.debugDescription)
        keep("15-dashboard-search-no-matches")

        app.buttons["Close search"].tap()
        XCTAssertTrue(app.buttons["session-row-home-shell-fixture:worker-running"].waitForExistence(timeout: 3), app.debugDescription)
    }

    @MainActor
    func testHomeButtonShowsWaitingForUser() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-dashboard-workers", "-dashboard-view-home", "-home-phase-active", "-home-waiting"]
        app.launch(); defer { app.terminate() }
        let home = app.buttons["home-floating-button"]
        XCTAssertTrue(home.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(waitFor(home, "value == 'Waiting for you'"), app.debugDescription)
        keep("03-home-button-waiting")
    }

    @MainActor
    func testHomeButtonShowsWorking() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-dashboard-workers", "-dashboard-view-home", "-home-phase-active"]
        app.launch(); defer { app.terminate() }
        let home = app.buttons["home-floating-button"]
        XCTAssertTrue(home.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(waitFor(home, "value == 'Working'"), app.debugDescription)
        keep("04-home-button-working")
    }

    /// View All shares its section title's line and sits at the row's trailing edge.
    @MainActor private func assertHeaderAction(_ action: XCUIElement, title: XCUIElement, app: XCUIApplication) {
        XCTAssertTrue(title.exists, app.debugDescription)
        XCTAssertEqual(action.label, "View all sessions in \(title.label)")
        XCTAssertEqual(action.frame.midY, title.frame.midY, accuracy: 2, "View All is on the title's line")
        XCTAssertGreaterThan(action.frame.minX, title.frame.maxX)
        XCTAssertGreaterThan(action.frame.maxX, app.frame.width * 0.85, "View All is right-aligned")
    }

    /// Replaces the search field's text through its clear button, so the
    /// journey types exactly what a user would.
    @MainActor private func replace(_ field: XCUIElement, with text: String, app: XCUIApplication) {
        let clear = app.buttons["Clear search"]
        if clear.exists { clear.tap() }
        field.typeText(text)
    }

    /// The shared placeholder's combined accessibility element.
    @MainActor private func noMatches(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'No matches'")).firstMatch
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func waitFor(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 10) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)], timeout: timeout) == .completed
    }

    @MainActor private func keep(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
