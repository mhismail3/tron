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
/// - a failed summary or re-tag clears existing summary/tags or offers no retry.
///
/// Take text is entered through the fixture's UIKit text-input control, not the
/// simulator keyboard, whose inline predictions commit extra words on a tap or
/// space. Keystroke typing during an in-flight save is covered in-process by
/// `KnowledgeDetailInteractionTests`.
final class TronKnowledgeDetailUITests: XCTestCase {
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
