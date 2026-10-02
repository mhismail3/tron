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
/// space. Keystroke typing during an in-flight save is covered in-process by
/// `KnowledgeDetailInteractionTests`.
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
