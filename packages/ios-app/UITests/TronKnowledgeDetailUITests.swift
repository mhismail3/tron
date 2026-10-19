import XCTest

/// Entry Detail interaction journeys against the hosted scripted Gateway
/// (`-tron-knowledge-detail-fixture`). The fixture keeps summary, take and tag
/// work pending until a journey completes or fails it, so each state below is
/// the production state machine, captured while it holds.
///
/// Failure modes these journeys protect:
/// - a double tap starts a second summary job (and a second charge);
/// - closing Entry Detail or losing the connection strands a running summary;
/// - a job event the app cannot decode silently leaves the sheet stale;
/// - autosave drops or rewrites the text being typed;
/// - an edit conflict or save failure discards the draft or offers no retry;
/// - an older failed save replaces newer typed text in the reopen draft;
/// - a failed summary or re-tag clears existing summary/tags or offers no retry;
/// - a curation conflict outcome leaves its saving indicator stuck or hides the current revision;
/// - a linked replacement that is archived or pending is unreadable despite its row authority.
///
/// Take text is entered through the fixture's UIKit text-input control, not the
/// simulator keyboard, whose inline predictions commit extra words on a tap or
/// space. Keystroke typing during an in-flight save is not exercised here.
final class TronKnowledgeDetailUITests: XCTestCase {
    @MainActor
    func testPresentedSummaryReconcilesAfterAppSwitchWithoutReplaying() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        let generate = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Generate AI summary")).firstMatch
        XCTAssertTrue(generate.waitForExistence(timeout: 10))
        generate.tap()
        XCTAssertTrue(counters(app, contain: "summarize:1"))
        let accepted = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Summary generation continues in the background.")).firstMatch
        XCTAssertTrue(accepted.waitForExistence(timeout: 10), "Observe the accepted job before backgrounding, not only its outgoing request")
        XCUIDevice.shared.press(.home)
        app.activate()
        let connected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH 'connected' AND NOT label CONTAINS 'socket:none'"), object: app.staticTexts["fixture.connection"])
        XCTAssertEqual(XCTWaiter.wait(for: [connected], timeout: 10), .completed)
        app.buttons["fixture.complete-summary"].tap()
        XCTAssertTrue(counters(app, contain: "summaryDone:1"), "The fixture must prove its server commit before testing client reconciliation. Timeline: \(app.staticTexts["fixture.counters"].value ?? "none")")
        let summary = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "A repository describing")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 20), "\(app.debugDescription)\nTimeline: \(app.staticTexts["fixture.counters"].value ?? "none")")
        XCTAssertTrue(counters(app, contain: "summarize:1"), "Recovery must query the original job, never replay it")
        let archive = app.buttons["Archive"]
        scrollTo(archive, in: app)
        archive.tap()
        XCTAssertTrue(app.buttons["Unarchive"].waitForExistence(timeout: 10), "Curation after reconnect must settle and refresh its new revision")
        app.buttons["Unarchive"].tap()
        XCTAssertTrue(app.buttons["Archive"].waitForExistence(timeout: 10))
        keepScreenshot(named: "348-presented-summary-after-app-switch")
    }

    @MainActor
    func testSummaryCommittedWhileBackgroundedReconcilesOnOriginalSheet() {
        continueAfterFailure = false
        let app = launch(scenario: "summary-background")
        defer { app.terminate() }
        let generate = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Generate AI summary")).firstMatch
        XCTAssertTrue(generate.waitForExistence(timeout: 10))
        generate.tap()
        XCTAssertTrue(counters(app, contain: "summarize:1"))
        let accepted = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Summary generation continues in the background.")).firstMatch
        XCTAssertTrue(accepted.waitForExistence(timeout: 10), "Observe the accepted job before backgrounding, not only its outgoing request")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(counters(app, contain: "summaryDone:1"), "The remote commit occurred while presentation was inactive")
        let summary = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "A repository describing")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 15), "Timeline: \(app.staticTexts["fixture.counters"].value ?? "none")")
        XCTAssertTrue(counters(app, contain: "summarize:1"))
        let timeline = XCTAttachment(string: "\(app.staticTexts["fixture.counters"].value ?? "none")")
        timeline.name = "348-background-summary-request-timeline"; timeline.lifetime = .keepAlways
        add(timeline)
        keepScreenshot(named: "348-summary-committed-while-backgrounded")
    }

    @MainActor
    func testLateSummaryStartAckKeepsNewerTakeOnSameConnection() {
        assertLateSummaryStartKeepsCurrentTake(reconnect: false)
    }

    @MainActor
    func testLateSummaryStartReceiptKeepsNewerTakeAfterReconnect() {
        assertLateSummaryStartKeepsCurrentTake(reconnect: true)
    }

    @MainActor
    private func assertLateSummaryStartKeepsCurrentTake(reconnect: Bool) {
        continueAfterFailure = false
        let app = launch(scenario: "summary-start-held")
        defer { app.terminate() }
        let generate = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Generate AI summary")).firstMatch
        XCTAssertTrue(generate.waitForExistence(timeout: 10)); generate.tap()
        XCTAssertTrue(counters(app, contain: "summarize:1"))
        let take = app.textViews["Your take"]
        scrollTo(take, in: app)
        app.buttons["fixture.type-take"].tap()
        XCTAssertTrue(counters(app, contain: "take:1"))
        let saved = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Saved '")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10), "The newer take is committed before the older start receipt is released")
        if reconnect {
            XCUIDevice.shared.press(.home); app.activate()
            let connected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH 'connected' AND NOT label CONTAINS 'socket:none'"), object: app.staticTexts["fixture.connection"])
            XCTAssertEqual(XCTWaiter.wait(for: [connected], timeout: 10), .completed)
            XCTAssertTrue(saved.waitForExistence(timeout: 10))
        }
        app.buttons["fixture.release-summary-start"].tap()
        XCTAssertTrue(counters(app, contain: "startAck:1"))
        let reverted = app.staticTexts["Private note · used to guide tagging and retrieval"]
        XCTAssertFalse(reverted.waitForExistence(timeout: 3), "An accepted job receipt is not the latest source record")
        XCTAssertEqual(take.value as? String, "chunk1 ")
        let archive = app.buttons["Archive"]; scrollTo(archive, in: app); archive.tap()
        XCTAssertTrue(app.buttons["Unarchive"].waitForExistence(timeout: 10), "The next mutation must use the current revision, not the receipt snapshot")
        XCTAssertTrue(counters(app, contain: "summarize:1"))
        let trace = XCTAttachment(string: "\(app.staticTexts["fixture.counters"].value ?? "none")")
        trace.name = "348-summary-start-current-row-\(reconnect)"; trace.lifetime = .keepAlways; add(trace)
        keepScreenshot(named: "348-summary-start-current-take-\(reconnect)")
    }

    @MainActor
    func testCorrectionCompletesIntoOriginalDetailAfterReconnect() {
        continueAfterFailure = false
        let app = launch(scenario: "superseded")
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Knowledge record actions"].waitForExistence(timeout: 10))
        app.buttons["Knowledge record actions"].tap()
        app.buttons["Correct record"].tap()
        XCTAssertTrue(app.staticTexts["Correct Knowledge"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.staticTexts["Correct Knowledge"].exists)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["Save"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, "Submission waits for the owning Mac to reconnect")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Corrected summary from the accepted correction."].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.staticTexts["Correct Knowledge"].exists, "The child completion must close its original sheet")
        XCTAssertTrue(counters(app, contain: "correction:1"))
        keepScreenshot(named: "348-correction-parent-settlement-after-reconnect")
    }

    @MainActor
    func testFullKnowledgeRefreshRemovesForgottenRowAndPublishesUpdatedNeighbor() {
        continueAfterFailure = false
        let app = launch(scenario: "dashboard-full-refresh")
        defer { app.terminate() }

        let rowA = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1284 Fixture A")).firstMatch
        let rowB = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1284 Fixture B")).firstMatch
        XCTAssertTrue(rowA.waitForExistence(timeout: 10), "The first real dashboard source row must mount: \(app.debugDescription)")
        XCTAssertTrue(rowB.waitForExistence(timeout: 10), "Keep B visible as the row updated by the external commit: \(app.debugDescription)")
        XCTAssertTrue(rowA.isHittable && rowB.isHittable, "Both baseline rows must be on-screen, not merely absent from a lazy viewport")

        let commit = app.buttons["fixture.commit-dashboard-full-refresh"]
        XCTAssertTrue(commit.waitForExistence(timeout: 5))
        commit.tap()
        XCTAssertTrue(counters(app, contain: "dashboardCommit:1"), "The external fixture commit removes A and changes B in the authoritative collection")
        XCTAssertTrue(counters(app, contain: "dashboardEvents:1"), "The whole-projection event was delivered through the hosted socket")
        XCTAssertTrue(counters(app, contain: "dashboardEventIDShape:missing"), "The event must omit recordIds, matching the whole-projection producer contract")
        XCTAssertTrue(counters(app, contain: "dashboardHeadResponseIDs:fixture-dashboard-b"), "The fresh first page contains B and omits A")
        XCTAssertTrue(counters(app, contain: "dashboardHeadResponseRevision:11"), "The fresh first page carries the committed revision")
        XCTAssertTrue(counters(app, contain: "dashboardExactReadIDs:fixture-dashboard-a"), "The retained A tail is checked through the existing exact-ID list request")
        let refreshedB = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1284 Fixture B refreshed")).firstMatch
        let refreshedBVisible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: refreshedB)
        XCTAssertEqual(XCTWaiter.wait(for: [refreshedBVisible], timeout: 10), .completed, "A fresh visible B is the production publication barrier: \(app.debugDescription)")
        let evidence = XCTAttachment(string: "\(app.debugDescription)\n\(app.staticTexts["fixture.counters"].value ?? "none")")
        evidence.name = "1284-full-refresh-dashboard-hierarchy-and-server-trace"
        evidence.lifetime = .keepAlways
        add(evidence)
        keepScreenshot(named: "1284-full-refresh-dashboard-updated-B")
        XCTAssertTrue(rowA.waitForNonExistence(timeout: 10), "After the refreshed B is visibly published, the production dashboard must not retain forgotten A: \(app.debugDescription)\nFixture: \(app.staticTexts["fixture.counters"].value ?? "none")")
        XCTAssertTrue(refreshedB.exists && refreshedB.isHittable, "The refreshed B remains the positive visible publication control")
    }

    @MainActor
    func testHeldContinuationRetiresAndFreshCursorStillLoads() {
        continueAfterFailure = false
        let app = launch(scenario: "dashboard-held-pagination")
        defer { app.terminate() }
        let rowB = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1284 Fixture B")).firstMatch
        XCTAssertTrue(rowB.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(counters(app, contain: "cursor[dashboard-initial-p2]"), app.staticTexts["fixture.counters"].value as? String ?? "")
        XCTAssertTrue(counters(app, contain: "dashboardHeld:1"), "The active continuation reply must be held before invalidation")
        let baselineA = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1284 Fixture A")).firstMatch
        XCTAssertTrue(baselineA.exists && baselineA.isHittable && rowB.isHittable, "Both baseline rows are visibly present before the fixture forgets A")

        app.buttons["fixture.commit-dashboard-full-refresh"].tap()
        let refreshedB = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1284 Fixture B refreshed")).firstMatch
        let refreshedBVisible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: refreshedB)
        XCTAssertEqual(XCTWaiter.wait(for: [refreshedBVisible], timeout: 10), .completed, "The admitted full refresh must publish visible B while Load More is held: \(app.debugDescription)")
        let forgottenA = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1284 Fixture A")).firstMatch
        XCTAssertTrue(forgottenA.waitForNonExistence(timeout: 5), "The fresh page removes forgotten A")
        app.buttons["fixture.release-dashboard-read"].tap()
        XCTAssertTrue(counters(app, contain: "dashboardReleased:1"), "The retired continuation response returned through the hosted socket")
        XCTAssertTrue(refreshedB.exists && refreshedB.isHittable, "The retired continuation cannot replace the fresh visible page")
        XCTAssertTrue(forgottenA.waitForNonExistence(timeout: 5), "The retired reply cannot restore a forgotten row")

        let loadMore = app.buttons["Load more"]
        XCTAssertTrue(loadMore.waitForExistence(timeout: 10), "Retiring a held continuation must release the native loading state; trace: \(app.staticTexts["fixture.counters"].value ?? "none")")
        XCTAssertTrue(loadMore.isEnabled)
        loadMore.tap()
        let rowD = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1284 Fixture D")).firstMatch
        XCTAssertTrue(rowD.waitForExistence(timeout: 10), "The page loaded from the fresh cursor must remain traversable: \(app.debugDescription)")
        XCTAssertTrue(counters(app, contain: "cursor[dashboard-fresh-p2]"))
        keepScreenshot(named: "1284-held-continuation-retired-and-fresh-cursor")
    }

    @MainActor
    func testCoveredReconciliationReAdmitsOnReveal() {
        continueAfterFailure = false
        let app = launch(scenario: "dashboard-cover-reveal")
        defer { app.terminate() }
        let rowB = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1284 Fixture B")).firstMatch
        XCTAssertTrue(rowB.waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["fixture.hold-dashboard-head"].tap()
        app.buttons["fixture.commit-dashboard-full-refresh"].tap()
        XCTAssertTrue(counters(app, contain: "dashboardHeld:1"), "The reconciliation head reply must be held before cover")

        app.buttons["dashboard.menu"].tap()
        app.buttons["Filter"].tap()
        XCTAssertTrue(app.staticTexts["Library filters"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(rowB.exists, "Covering the filter sheet retains the accepted dashboard window")
        XCTAssertTrue(counters(app, contain: "dashboardHeadReads:2"), "The covered dashboard must not admit replacement work while its original head reply is held")
        app.buttons["Done"].tap()

        XCTAssertTrue(counters(app, contain: "dashboardHeadReads:3"), "Reveal must admit a new authoritative head while the retired reply remains held; trace: \(app.staticTexts["fixture.counters"].value ?? "none")")
        let refreshedB = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1284 Fixture B refreshed")).firstMatch
        let refreshedBVisible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: refreshedB)
        XCTAssertEqual(XCTWaiter.wait(for: [refreshedBVisible], timeout: 10), .completed, "The fresh revealed reconciliation must publish visible B: \(app.debugDescription)")
        XCTAssertTrue(counters(app, contain: "head@r11=fixture-dashboard-b"), "The third head request must observe the committed authoritative rows")
        let forgottenA = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1284 Fixture A")).firstMatch
        XCTAssertTrue(forgottenA.waitForNonExistence(timeout: 5), "The revealed authoritative page removes forgotten A")
        app.buttons["fixture.release-dashboard-read"].tap()
        XCTAssertTrue(counters(app, contain: "dashboardReleased:1"))
        XCTAssertTrue(refreshedB.exists && refreshedB.isHittable, "The retired covered reply cannot overwrite the revealed publication")
        XCTAssertTrue(forgottenA.waitForNonExistence(timeout: 5))
        keepScreenshot(named: "1284-covered-reconciliation-readmitted-on-reveal")
    }

    @MainActor
    func testSearchRefreshReplacesThePriorQueryMembership() {
        continueAfterFailure = false
        let app = launch(scenario: "dashboard-search-refresh")
        defer { app.terminate() }
        app.buttons["dashboard.menu"].tap()
        app.buttons["Search"].tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(app.textFields.count, 1, "The open dashboard search has exactly one native text field")
        field.tap()
        field.typeText("Fixture")
        XCTAssertTrue(counters(app, contain: "dashboardSearches:1"), "The query is admitted through the real search request")
        let rowA = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1284 Fixture A")).firstMatch
        let rowB = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1284 Fixture B")).firstMatch
        XCTAssertTrue(rowA.exists && rowA.isHittable && rowB.isHittable, app.debugDescription)
        app.buttons["fixture.commit-dashboard-full-refresh"].tap()
        let refreshedB = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1284 Fixture B refreshed")).firstMatch
        let publication = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: refreshedB)
        XCTAssertEqual(XCTWaiter.wait(for: [publication], timeout: 10), .completed, app.debugDescription)
        XCTAssertTrue(counters(app, contain: "dashboardSearchRevision:11"))
        XCTAssertTrue(rowA.waitForNonExistence(timeout: 5), "A fresh query result must not append the forgotten prior-query member A: \(app.debugDescription)")
        keepScreenshot(named: "1284-search-membership-replaced")
    }

    @MainActor
    func testSynthesesRefreshRemovesForgottenRecordMembership() {
        continueAfterFailure = false
        let app = launch(scenario: "dashboard-records-refresh")
        defer { app.terminate() }
        app.buttons["dashboard.menu"].tap()
        app.buttons["Filter"].tap()
        XCTAssertTrue(app.staticTexts["Library filters"].waitForExistence(timeout: 5))
        app.buttons["Syntheses"].tap()
        app.buttons["Done"].tap()
        let rowA = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1284 Fixture A")).firstMatch
        let rowB = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1284 Fixture B")).firstMatch
        XCTAssertTrue(rowA.waitForExistence(timeout: 10) && rowA.isHittable && rowB.isHittable, app.debugDescription)
        app.buttons["fixture.commit-dashboard-full-refresh"].tap()
        let refreshedB = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1284 Fixture B refreshed")).firstMatch
        let publication = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: refreshedB)
        XCTAssertEqual(XCTWaiter.wait(for: [publication], timeout: 10), .completed, app.debugDescription)
        XCTAssertTrue(rowA.waitForNonExistence(timeout: 5), "A fresh Records page must not retain forgotten A behind visible refreshed B: \(app.debugDescription)")
        keepScreenshot(named: "1284-record-membership-reconciled")
    }

    @MainActor
    func testPagedSearchRetainsDepthAndSupersedesConflictedCut() {
        continueAfterFailure = false
        let app = launch(scenario: "dashboard-search-retain")
        defer { app.terminate() }
        XCTAssertTrue(counters(app, contain: "dashboardHeld:1"), "Hold the unsearched catalogue so it cannot masquerade as query publication")
        app.buttons["dashboard.menu"].tap()
        app.buttons["Search"].tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("Fixture")
        let rowC = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1284 Fixture C")).firstMatch
        XCTAssertTrue(rowC.waitForExistence(timeout: 10) && rowC.isHittable, "C must be visibly loaded through the query's continuation: \(app.debugDescription)")
        XCTAssertTrue(counters(app, contain: "dashboardSearches:2"))
        app.buttons["fixture.commit-dashboard-full-refresh"].tap()
        waitForKnowledgeInvalidation(1, in: app)
        XCTAssertTrue(counters(app, contain: "dashboardHeld:2"), "The fresh query head is held at cut 11")
        XCTAssertTrue(rowC.exists && rowC.isHittable, "Refreshing must retain the reader's accepted deeper query window")
        app.buttons["fixture.commit-dashboard-full-refresh"].tap()
        waitForKnowledgeInvalidation(2, in: app)
        app.buttons["fixture.release-dashboard-read"].tap()
        let newestB = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1284 Fixture B newest 2")).firstMatch
        let publication = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: newestB)
        XCTAssertEqual(XCTWaiter.wait(for: [publication], timeout: 10), .completed, "The observed newer event must supersede a conflicted scored cut without another user retry: \(app.debugDescription)")
        XCTAssertTrue(rowC.exists && rowC.isHittable, "An unchanged loaded search tail must survive rather than jump back to the first page")
        XCTAssertTrue(counters(app, contain: "dashboardSearchConflicts:1"), "Rebuilding the loaded depth must challenge the stale cut-11 continuation before the cut-12 followup")
        let rowA = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1284 Fixture A")).firstMatch
        XCTAssertTrue(rowA.waitForNonExistence(timeout: 5))
        app.buttons["fixture.release-dashboard-read"].tap()
        XCTAssertTrue(counters(app, contain: "dashboardReleased:2"))
        XCTAssertTrue(newestB.exists && newestB.isHittable && rowC.isHittable, "The late retired catalogue cannot overwrite the accepted query window")
        XCTAssertTrue(rowA.waitForNonExistence(timeout: 5))
        keepScreenshot(named: "1284-paged-query-depth-and-conflict-followup")
    }

    /// Knowledge is one library: it opens on Sources with no Chronicle area, and
    /// the retired Chronicle's records stay a labelled, searchable, cited collection.
    @MainActor
    func testLegacyHistoryIsOneLabelledSearchableLibraryCollection() {
        continueAfterFailure = false
        for appearance in ["dark", "light"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-knowledge-detail-fixture", "-knowledge-detail-scenario", "dashboard-legacy-history",
                                   "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + (appearance == "light" ? ["-knowledge-light"] : [])
            app.launch()
            let rowA = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1284 Fixture A")).firstMatch
            XCTAssertTrue(rowA.waitForExistence(timeout: 10), "Knowledge opens on Library Sources: \(app.debugDescription)")
            XCTAssertFalse(app.buttons["Chronicle"].exists || app.staticTexts["Chronicle"].exists, "No separate Chronicle area remains")
            keepScreenshot(named: "knowledge-library-default-\(appearance)")
            app.buttons["dashboard.menu"].tap()
            XCTAssertFalse(app.buttons["Chronicle info"].exists, "The retired Chronicle has no status surface of its own")
            app.buttons["Filter"].tap()
            XCTAssertTrue(app.staticTexts["Library filters"].waitForExistence(timeout: 5))
            keepScreenshot(named: "knowledge-library-filters-\(appearance)")
            app.buttons["Legacy history"].tap()
            app.buttons["Done"].tap()
            let caption = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Conversation observations saved before automatic capture ended")).firstMatch
            XCTAssertTrue(caption.waitForExistence(timeout: 10), "Legacy history is labelled as preserved, read-only history: \(app.debugDescription)")
            // Observation records replace the previous collection's source rows.
            let sourceStyled = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Web page")).firstMatch
            XCTAssertTrue(sourceStyled.waitForNonExistence(timeout: 10), "Legacy history presents observation records: \(app.debugDescription)")
            XCTAssertTrue(rowA.waitForExistence(timeout: 10) && rowA.isHittable, "Preserved observation records remain readable")
            keepScreenshot(named: "knowledge-legacy-history-\(appearance)")
            app.buttons["dashboard.menu"].tap()
            app.buttons["Search"].tap()
            let field = app.textFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap(); field.typeText("Fixture B")
            let rowB = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1284 Fixture B")).firstMatch
            XCTAssertTrue(counters(app, contain: "dashboardSearches:1"), "The query searches legacy history through knowledge.search")
            XCTAssertTrue(rowB.waitForExistence(timeout: 10) && rowA.waitForNonExistence(timeout: 5), "Search narrows legacy history: \(app.debugDescription)")
            rowB.tap()
            XCTAssertTrue(app.buttons["Open session"].waitForExistence(timeout: 10),
                          "The record opens with its cited originating chat: \(app.debugDescription)")
            keepScreenshot(named: "knowledge-legacy-history-detail-\(appearance)")
            app.terminate()
        }
    }

    @MainActor
    func testInvalidationDuringFirstLibraryReadIsNotDropped() {
        continueAfterFailure = false
        let app = launch(scenario: "dashboard-initial-records")
        defer { app.terminate() }
        XCTAssertTrue(counters(app, contain: "dashboardHeld:1"), "The first Sources reply is held before any page can publish")
        app.buttons["fixture.commit-dashboard-full-refresh"].tap()
        waitForKnowledgeInvalidation(1, in: app)
        app.buttons["fixture.release-dashboard-read"].tap()
        let refreshedB = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1284 Fixture B refreshed")).firstMatch
        let publication = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: refreshedB)
        XCTAssertEqual(XCTWaiter.wait(for: [publication], timeout: 10), .completed, "An invalidation observed before the initial page exists must still converge: \(app.debugDescription)")
        let rowA = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1284 Fixture A")).firstMatch
        XCTAssertTrue(rowA.waitForNonExistence(timeout: 5), "The late initial Sources snapshot cannot leave forgotten A behind")
        keepScreenshot(named: "1284-initial-records-invalidation-consumed")
    }

    @MainActor
    func testCachedAndWrongFilterRowsWaitForAuthoritativeReplacement() {
        continueAfterFailure = false
        let app = launch(scenario: "dashboard-cache-race")
        defer { app.terminate() }
        let rowA = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1284 Fixture A")).firstMatch
        let rowC = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1284 Fixture C")).firstMatch
        XCTAssertTrue(rowA.waitForExistence(timeout: 10) && rowA.isHittable && rowC.isHittable, app.debugDescription)
        app.buttons["fixture.close-detail"].tap()
        XCTAssertTrue(app.staticTexts["Knowledge dashboard closed"].waitForExistence(timeout: 5))
        app.buttons["fixture.commit-dashboard-full-refresh"].tap()
        XCTAssertTrue(counters(app, contain: "dashboardCommit:1"))
        waitForKnowledgeInvalidation(1, in: app)
        app.buttons["fixture.hold-dashboard-head"].tap()
        app.buttons["fixture.open-detail"].tap()
        XCTAssertTrue(counters(app, contain: "dashboardHeld:1"))
        XCTAssertTrue(rowA.waitForExistence(timeout: 5) && rowA.isHittable, "Forgotten A is visibly coming from the real provisional cache while its replacement is held")
        app.buttons["fixture.commit-dashboard-full-refresh"].tap()
        XCTAssertTrue(counters(app, contain: "dashboardEvents:2"))
        waitForKnowledgeInvalidation(2, in: app)
        app.buttons["fixture.release-dashboard-read"].tap()
        let newestB = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1284 Fixture B newest 2")).firstMatch
        let firstPublication = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: newestB)
        XCTAssertEqual(XCTWaiter.wait(for: [firstPublication], timeout: 10), .completed, app.debugDescription)
        XCTAssertTrue(rowA.waitForNonExistence(timeout: 5), "A target-only event cannot certify forgotten cached A")
        XCTAssertTrue(rowC.exists && rowC.isHittable, "Unchanged research C is retained in the accepted all-scopes page")
        app.buttons["fixture.inspect-dashboard-reads"].tap()
        XCTAssertTrue(counters(app, contain: "dashboardInspection:1"))
        XCTAssertTrue(counters(app, contain: "dashboardHeadsWhileHeld:0"), "No reconciliation may supersede an uncertified cached replacement")

        app.buttons["fixture.hold-dashboard-head"].tap()
        app.buttons["dashboard.menu"].tap()
        app.buttons["Filter"].tap()
        app.buttons["Personal"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(counters(app, contain: "dashboardHeld:2"))
        XCTAssertTrue(rowC.exists && rowC.isHittable, "The previous all-scopes window remains provisional while the Personal replacement is held")
        app.buttons["fixture.commit-dashboard-full-refresh"].tap()
        XCTAssertTrue(counters(app, contain: "dashboardEvents:3"))
        waitForKnowledgeInvalidation(3, in: app)
        app.buttons["fixture.release-dashboard-read"].tap()
        let personalB = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1284 Fixture B newest 3")).firstMatch
        let secondPublication = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: personalB)
        XCTAssertEqual(XCTWaiter.wait(for: [secondPublication], timeout: 10), .completed, app.debugDescription)
        XCTAssertTrue(rowC.waitForNonExistence(timeout: 5), "Research C must not be certified by the Personal filter's target-only event")
        app.buttons["fixture.inspect-dashboard-reads"].tap()
        XCTAssertTrue(counters(app, contain: "dashboardInspection:2"))
        XCTAssertTrue(counters(app, contain: "dashboardHeadsWhileHeld:0"), "A wrong-key retained page cannot admit reconciliation before its replacement")
        XCTAssertTrue(counters(app, contain: "dashboardReleased:2"))
        keepScreenshot(named: "1284-cache-and-filter-authority")
    }

    @MainActor
    func testFullPassConsumesItsCutBeforeTargetedFollowup() {
        continueAfterFailure = false
        let app = launch(scenario: "dashboard-overlap-intent")
        defer { app.terminate() }
        let rowC = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1284 Fixture C")).firstMatch
        XCTAssertTrue(rowC.waitForExistence(timeout: 10) && rowC.isHittable, "C is admitted by a real continuation, not the first head")
        XCTAssertTrue(counters(app, contain: "cursor[dashboard-overlap-p2]"))
        app.buttons["fixture.hold-dashboard-tail"].tap()
        app.buttons["fixture.commit-dashboard-full-refresh"].tap()
        XCTAssertTrue(counters(app, contain: "dashboardHeld:1"), "Hold C's exact read during a full retained-window pass")
        app.buttons["fixture.commit-dashboard-full-refresh"].tap()
        XCTAssertTrue(counters(app, contain: "dashboardEventIDShape:count:1"), "Only B changed after the full pass's captured cut")
        waitForKnowledgeInvalidation(2, in: app)
        app.buttons["fixture.release-dashboard-read"].tap()
        let newestB = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1284 Fixture B newest 2")).firstMatch
        let newestVisible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: newestB)
        XCTAssertEqual(XCTWaiter.wait(for: [newestVisible], timeout: 10), .completed, app.debugDescription)
        let refreshedC = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1284 Fixture C refreshed")).firstMatch
        XCTAssertTrue(refreshedC.exists && refreshedC.isHittable, "The full pass really published its refreshed retained tail before the target-only followup settled")
        // Observe backend traffic after both positive native publications. A
        // pre-publication counter could accidentally accept an in-flight mutant.
        app.buttons["fixture.inspect-dashboard-reads"].tap()
        XCTAssertTrue(counters(app, contain: "dashboardInspection:1"))
        XCTAssertTrue(counters(app, contain: "dashboardExactReads:1 "), "The later B-only intent must not run another full C-tail read: \(app.staticTexts["fixture.counters"].value ?? "none")")
        keepScreenshot(named: "1284-full-cut-consumed-before-targeted-followup")
    }

    @MainActor
    func testShortMiddlePageDoesNotEndSourcePagination() {
        continueAfterFailure = false
        let app = launch(scenario: "dashboard-pagination-control")
        defer { app.terminate() }
        let rowD = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1284 Fixture D")).firstMatch
        XCTAssertTrue(rowD.waitForExistence(timeout: 10) && rowD.isHittable, "A one-row middle page with a cursor must still admit the final page")
        XCTAssertTrue(counters(app, contain: "cursor[dashboard-page-2]"))
        XCTAssertTrue(counters(app, contain: "cursor[dashboard-page-3]"))
    }

    /// This is only event admission. Every journey separately observes fresh
    /// native rows before asserting membership or backend traffic.
    @MainActor
    private func waitForKnowledgeInvalidation(_ revision: Int, in app: XCUIApplication) {
        let admitted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "invalidation:\(revision) "), object: app.staticTexts["fixture.connection"])
        XCTAssertEqual(XCTWaiter.wait(for: [admitted], timeout: 10), .completed, app.debugDescription)
    }

    @MainActor
    func testLateSourceRowsCannotOverwriteNewerTagsOnSameConnection() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        let initial = app.staticTexts["Workflows"]
        scrollTo(initial, in: app)
        XCTAssertTrue(initial.waitForExistence(timeout: 10))
        app.buttons["fixture.hold-rows"].tap()
        XCTAssertTrue(counters(app, contain: "held:1"))
        app.buttons["fixture.newer-tags"].tap()
        XCTAssertTrue(app.staticTexts["Evaluation"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["fixture.release-rows"].tap()
        XCTAssertTrue(counters(app, contain: "released:1"))
        XCTAssertFalse(initial.waitForExistence(timeout: 2), "The delivered older read must not replace newer tags on the same socket")
        XCTAssertTrue(app.staticTexts["Evaluation"].exists)
        keepScreenshot(named: "348-late-source-read-rejected")
    }

    @MainActor
    func testArchiveAndUnarchiveRoundTripUsesAdmissionLabels() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        let archive = app.buttons["Archive"]
        scrollTo(archive, in: app)
        XCTAssertTrue(archive.waitForExistence(timeout: 10), app.debugDescription)
        archive.tap()
        let unarchive = app.buttons["Unarchive"]
        XCTAssertTrue(unarchive.waitForExistence(timeout: 10), "Archiving changes the row action to Unarchive: \(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["Archived"].exists, "The admission row is labeled Archived")
        unarchive.tap()
        XCTAssertTrue(app.buttons["Archive"].waitForExistence(timeout: 10), "Restoring changes the row action back to Archive: \(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["Archive"].exists)
    }

    @MainActor
    func testCurationConflictShowsErrorReloadsAndReenablesVerdictControl() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        let verdict = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Verdict, not judged")).firstMatch
        scrollTo(verdict, in: app)
        XCTAssertTrue(verdict.waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["fixture.next-curation-conflict"].tap()
        verdict.tap()
        app.buttons["Dated but useful"].tap()

        let error = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Another edit changed this source.")).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 10), "A rejected curation outcome is visible: \(app.debugDescription)")
        XCTAssertTrue(verdict.isEnabled, "The conflict clears the saving state so another edit is possible")
        verdict.tap()
        XCTAssertTrue(app.buttons["Dated but useful"].waitForExistence(timeout: 5), "The verdict control opens again after conflict")
        app.buttons["Dated but useful"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Dated")).firstMatch.waitForExistence(timeout: 10))
    }

    @MainActor
    func testSummaryRunsInBackgroundAcrossCloseAndReconnect() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        let generate = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Generate AI summary")).firstMatch
        XCTAssertTrue(generate.waitForExistence(timeout: 10), app.debugDescription)
        keepScreenshot(named: "k7-default")

        generate.tap()
        generate.tap()
        XCTAssertTrue(counters(app, contain: "summarize:1"), "A double tap must start exactly one summary job")
        let running = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "continues in the background")).firstMatch
        XCTAssertTrue(running.waitForExistence(timeout: 5), app.debugDescription)
        keepScreenshot(named: "k7-generating")

        // Closing Entry Detail does not strand the job: a new detail queries it.
        app.buttons["fixture.close-detail"].tap()
        XCTAssertTrue(app.staticTexts["Entry Detail closed"].waitForExistence(timeout: 3))
        app.buttons["fixture.open-detail"].tap()
        XCTAssertTrue(running.waitForExistence(timeout: 8), "Reopened detail must show the still-running job: \(app.debugDescription)")

        // The job finishes while the link is down; reconnect re-queries it.
        app.buttons["fixture.drop-connection"].tap()
        app.buttons["fixture.complete-summary"].tap()
        XCTAssertTrue(counters(app, contain: "summaryDone:1"), "The fixture must prove its server commit before testing client reconciliation. Timeline: \(app.staticTexts["fixture.counters"].value ?? "none")")
        let summary = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "A repository describing")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 30), "Reconnect must surface the finished summary: \(app.debugDescription)")
        XCTAssertTrue(counters(app, contain: "summarize:1"), "Recovery must not start another summary job")
        keepScreenshot(named: "k7-summary-tags")
    }

    @MainActor
    func testFailedRegenerationKeepsSummaryAndOffersRetry() {
        continueAfterFailure = false
        let app = launch(scenario: "superseded")
        defer { app.terminate() }
        let existing = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "A worked playbook")).firstMatch
        XCTAssertTrue(existing.waitForExistence(timeout: 10), app.debugDescription)
        let replacement = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Replaced by: Harness design, revised")).firstMatch
        scrollTo(replacement, in: app)
        XCTAssertTrue(replacement.exists, "A superseded entry shows what replaced it: \(app.debugDescription)")
        keepScreenshot(named: "k7-superseded-replacement")

        let regenerate = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Regenerate AI summary")).firstMatch
        scrollTo(regenerate, in: app, upward: true)
        regenerate.tap()
        XCTAssertTrue(counters(app, contain: "summarize:1"))
        app.buttons["fixture.fail-summary"].tap()
        let retry = app.buttons["Retry summary"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(existing.exists, "A failed regeneration keeps the existing summary")
        keepScreenshot(named: "k7-summary-failure-retry")
        retry.tap()
        XCTAssertTrue(counters(app, contain: "summarize:2"), "Retry starts a new summary job")
    }

    @MainActor
    func testTakeAutosavesKeepsDraftOnConflictAndFailureAndRetags() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        let take = app.textViews["Your take"]
        XCTAssertTrue(take.waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["fixture.type-take"].tap()
        XCTAssertTrue(counters(app, contain: "take:1"), "Autosave after the typing pause: \(app.debugDescription)")

        let updating = updatingTags(app)
        scrollTo(updating, in: app)
        XCTAssertTrue(updating.waitForExistence(timeout: 10), "A saved take re-tags in the background: \(app.debugDescription)")
        keepScreenshot(named: "k7-updating-tags")
        app.buttons["fixture.complete-tags"].tap()
        XCTAssertTrue(app.staticTexts["Agent harness"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(updating.exists)

        // Another device saves first: the typed draft is kept and both are shown.
        app.buttons["fixture.next-take-conflict"].tap()
        app.buttons["fixture.type-take"].tap()
        XCTAssertTrue(counters(app, contain: "take:2"))
        let current = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Remote edit from another device")).firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(take.value as? String, "chunk1 chunk2 ", "A conflict must keep the typed draft")
        keepScreenshot(named: "k7-take-conflict")
        app.buttons["Retry"].tap()
        XCTAssertTrue(counters(app, contain: "take:3"), "Retry saves the draft over the current revision")
        XCTAssertFalse(current.waitForExistence(timeout: 2), "A saved retry clears the conflict")
        XCTAssertTrue(updatingTags(app).waitForExistence(timeout: 10))
        app.buttons["fixture.complete-tags"].tap()

        // A failed save keeps the draft and retries on request.
        app.buttons["fixture.next-take-failure"].tap()
        app.buttons["fixture.type-take"].tap()
        XCTAssertTrue(counters(app, contain: "take:4"))
        let retry = app.buttons["Retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(take.value as? String, "chunk1 chunk2 chunk3 ", "A failed save must keep the draft")
        keepScreenshot(named: "k7-take-save-failure-retry")
        retry.tap()
        XCTAssertTrue(counters(app, contain: "take:5"))
        XCTAssertFalse(app.buttons["Retry"].waitForExistence(timeout: 2))
        XCTAssertEqual(take.value as? String, "chunk1 chunk2 chunk3 ")
    }

    @MainActor
    func testOlderFailedTakeKeepsNewerDraftAfterReopen() {
        assertOlderFailureCannotReplaceRegistry(settleNewerSuccessfully: false)
    }

    @MainActor
    func testOlderFailedTakeCannotResurrectSettledDraft() {
        assertOlderFailureCannotReplaceRegistry(settleNewerSuccessfully: true)
    }

    @MainActor
    func testRetiredTakeFailureCannotAttachToReplacementMac() {
        continueAfterFailure = false
        let app = launch(scenario: "take-failure-held")
        defer { app.terminate() }
        let take = app.textViews["Your take"]
        XCTAssertTrue(take.waitForExistence(timeout: 10))
        scrollTo(take, in: app)
        app.buttons["fixture.type-take"].tap()
        XCTAssertTrue(counters(app, contain: "takeHeld:1"))
        app.buttons["fixture.replace-profile"].tap()
        let replacementReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH 'connected' AND label CONTAINS 'profile:knowledge-replacement' AND NOT label CONTAINS 'socket:none'"),
            object: app.staticTexts["fixture.connection"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [replacementReady], timeout: 15), .completed)
        app.buttons["fixture.open-detail"].tap()
        XCTAssertTrue(take.waitForExistence(timeout: 10))
        XCTAssertEqual(take.value as? String, "", "The same record ID on another Mac cannot inherit the original draft")
        app.buttons["fixture.type-take"].tap()
        let saved = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Saved '")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10), "The replacement's own take settles canonically")
        app.buttons["fixture.release-take"].tap()
        XCTAssertTrue(counters(app, contain: "takeReleased:1"))
        XCTAssertFalse(app.buttons["Retry"].exists, "The retired command's error cannot attach to replacement authority")
        app.buttons["fixture.close-detail"].tap()
        XCTAssertTrue(app.staticTexts["Entry Detail closed"].waitForExistence(timeout: 10))
        app.buttons["fixture.open-detail"].tap()
        XCTAssertTrue(take.waitForExistence(timeout: 10))
        XCTAssertEqual(take.value as? String, "chunk2 ", "Replacement authority retains only its own successful text")
        keepScreenshot(named: "354-retired-take-replacement-authority")
    }

    @MainActor
    private func assertOlderFailureCannotReplaceRegistry(settleNewerSuccessfully: Bool) {
        continueAfterFailure = false
        let app = launch(scenario: "take-failure-held")
        defer { app.terminate() }
        let take = app.textViews["Your take"]
        XCTAssertTrue(take.waitForExistence(timeout: 10), app.debugDescription)
        scrollTo(take, in: app)
        app.buttons["fixture.type-take"].tap()
        XCTAssertTrue(counters(app, contain: "takeHeld:1"), "Observe the first real save held before editing again")
        app.buttons["fixture.type-take"].tap()
        XCTAssertEqual(take.value as? String, "chunk1 chunk2 ")
        let parallelSave = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS 'take:2'"),
            object: app.staticTexts["fixture.counters"]
        )
        parallelSave.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [parallelSave], timeout: 1), .completed,
                       "The newer autosave cannot dispatch while the first save remains held")
        app.buttons["fixture.release-take"].tap()
        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 10), "Observe the first failed save's settlement before closing")
        XCTAssertEqual(take.value as? String, "chunk1 chunk2 ", "A failed earlier save must not rewrite the visible edit")
        app.buttons["fixture.close-detail"].tap()
        XCTAssertTrue(app.staticTexts["Entry Detail closed"].waitForExistence(timeout: 10))
        XCTAssertTrue(counters(app, contain: "takeHeld:2"), "Hold the existing dismissal flush so canonical success cannot mask a lost registry draft")
        XCTAssertTrue(counters(app, contain: "takeCommands:2"), "Dismissal submits a distinct newer command, not replay of the failed original")
        XCTAssertTrue(counters(app, contain: "latestTake:true"), "The held dismissal flush captured the newer input")
        app.buttons["fixture.open-detail"].tap()
        XCTAssertTrue(take.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(take.value as? String, "chunk1 chunk2 ", "Reopening must restore the newer draft, not the older failed submission")

        // The previous leaf still owns its held dismissal flush. A subsequent
        // edit belongs to the reopened editor/registry, not that stale leaf.
        app.buttons["fixture.type-take"].tap()
        XCTAssertEqual(take.value as? String, "chunk1 chunk2 chunk3 ")
        app.buttons["fixture.close-detail"].tap()
        XCTAssertTrue(app.staticTexts["Entry Detail closed"].waitForExistence(timeout: 10))
        XCTAssertTrue(counters(app, contain: "takeHeld:3"), "The newer editor's dismissal flush owns the latest registry draft")
        XCTAssertTrue(counters(app, contain: "takeCommands:3"))
        if settleNewerSuccessfully {
            app.buttons["fixture.complete-latest-take"].tap()
            XCTAssertTrue(counters(app, contain: "takeSucceeded:1"), "A newer accepted save settles before the old failure; its matching draft is cleared")
        }
        app.buttons["fixture.release-take"].tap()
        XCTAssertTrue(counters(app, contain: settleNewerSuccessfully ? "takeReleased:3" : "takeReleased:2"), "The older dismissal flush fails after the newer draft acquired its own command")
        app.buttons["fixture.open-detail"].tap()
        XCTAssertTrue(take.waitForExistence(timeout: 10))
        XCTAssertEqual(take.value as? String, "chunk1 chunk2 chunk3 ", "A late failure from the prior leaf must not overwrite the current registry draft")
        let timeline = XCTAttachment(string: "\(app.staticTexts["fixture.counters"].value ?? "none")")
        timeline.name = "354-older-failed-take-newer-draft-reopen-success-\(settleNewerSuccessfully)"; timeline.lifetime = .keepAlways
        add(timeline)
        keepScreenshot(named: "354-older-failed-take-newer-draft-reopen")
    }

    @MainActor
    func testFailedRetagKeepsTagsAndRetries() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        let take = app.textViews["Your take"]
        XCTAssertTrue(take.waitForExistence(timeout: 10), app.debugDescription)
        scrollTo(take, in: app)
        app.buttons["fixture.type-take"].tap()
        XCTAssertTrue(counters(app, contain: "take:1"))
        XCTAssertTrue(updatingTags(app).waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["fixture.fail-tags"].tap()
        let retry = app.buttons["Retry tagging"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Workflows"].exists, "A failed re-tag keeps the current tags")
        keepScreenshot(named: "k7-tag-failure-retry")
        retry.tap()
        XCTAssertTrue(counters(app, contain: "tag:1"), "Retry starts one explicit re-tag")
        XCTAssertTrue(updatingTags(app).waitForExistence(timeout: 10))
        app.buttons["fixture.complete-tags"].tap()
        XCTAssertTrue(app.staticTexts["Agent harness"].waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor
    func testPersonalScopeEntry() {
        continueAfterFailure = false
        let app = launch(scenario: "personal")
        defer { app.terminate() }
        let scope = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Scope, Personal")).firstMatch
        XCTAssertTrue(app.textViews["Your take"].waitForExistence(timeout: 10), app.debugDescription)
        scrollTo(scope, in: app)
        XCTAssertTrue(scope.exists, app.debugDescription)
        keepScreenshot(named: "k7-personal-scope")
    }

    @MainActor
    func testForgetConfirmationCancelsWithoutWritingThenCommitsWhileParentCovered() {
        let app = launch(scenario: "forget-confirmation"); defer { app.terminate() }
        let actions = app.buttons["Knowledge record actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10)); actions.tap()
        app.buttons["Forget permanently"].tap()
        XCTAssertTrue(app.buttons["confirmation-cancel"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.alerts.count, 0)
        app.buttons["confirmation-cancel"].tap()
        XCTAssertTrue(counters(app, contain: "forget:0"))
        actions.tap(); app.buttons["Forget permanently"].tap()
        app.buttons["Forget"].tap()
        XCTAssertTrue(actions.waitForNonExistence(timeout: 5), "The accepted receipt dismisses Entry Detail")
        XCTAssertTrue(counters(app, contain: "forget:1"))
        keepScreenshot(named: "1261-forget-covered-parent")
    }

    // MARK: - Helpers

    @MainActor
    private func launch(scenario: String = "default") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-knowledge-detail-fixture", "-knowledge-detail-scenario", scenario, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    /// The Tags row merges its title and status into one accessibility element.
    @MainActor
    private func updatingTags(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Updating tags")).firstMatch
    }

    @MainActor
    private func counters(_ app: XCUIApplication, contain value: String) -> Bool {
        let element = app.staticTexts["fixture.counters"]
        let predicate = NSPredicate(format: "label CONTAINS %@", value)
        return XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: 10) == .completed
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, upward: Bool = false) {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            let scroll = app.scrollViews.firstMatch
            if upward { scroll.swipeDown() } else { scroll.swipeUp() }
        }
    }

    @MainActor
    private func keepScreenshot(named name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
