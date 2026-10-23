import XCTest

/// Production SwiftUI and typed Gateway sockets: each case observes a user-visible
/// outcome. No source, token or fixture-constant-only assertions.
final class TronConsolidatedUIRegressionTests: XCTestCase {
    @MainActor func testMemoryToolRowsAndCanonicalNavigation() {
        let app = home(["-memory-redesign"]); defer { app.terminate() }
        manageHome(app)
        tap(app, "home-manage-memory-browser")
        let result = element(app, "home-memory-row-38")
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertTrue(result.label.contains("Read File") && result.label.contains("Completed"), result.label)
        XCTAssertFalse(result.label.contains("import") || result.label.contains("interface"), "Rows never expose arbitrary output")
        tap(app, "home-memory-row-38")
        XCTAssertTrue(element(app, "home-memory-detail").waitForExistence(timeout: 5))
        let summary = app.staticTexts["Reviewed the memory contract and preserved the canonical source identity."]
        let output = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'export interface MemoryRecord'")).firstMatch
        XCTAssertTrue(summary.exists && output.exists, app.debugDescription)
        XCTAssertLessThan(summary.frame.minY, output.frame.minY, "Summary precedes the literal tool output")
        tap(app, "home-memory-info")
        XCTAssertTrue(element(app, "home-memory-technical-details").waitForExistence(timeout: 5))
        close(app)
        tap(app, "home-memory-canonical-transcript")
        XCTAssertTrue(element(app, "home-evidence-text").waitForExistence(timeout: 5))
        keep("memory-canonical-navigation")
    }

    @MainActor func testMemoryCountIsTheTagWithoutDuplicateSubtext() {
        let app = home(["-memory-redesign"]); defer { app.terminate() }
        manageHome(app); tap(app, "home-manage-memory-browser")
        let row = element(app, "home-memory-summary-32-2")
        reveal(app, row)
        let tags = row.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Summary of '"))
        XCTAssertEqual(tags.count, 1, "The count is presented once as the summary tag: \(row.debugDescription)")
        XCTAssertFalse(row.staticTexts["Summary"].exists, "No count-less duplicate attribution tag")
        row.tap()
        XCTAssertTrue(element(app, "home-memory-summary-detail").waitForExistence(timeout: 5))
        keep("memory-counted-summary")
    }

    @MainActor func testHistoryMetadataSharesTitleTextEdge() {
        let app = session(["-manage-session-review", "-history-large"]); defer { app.terminate() }
        tap(app, "Session History"); tap(app, "history-row-h-6732")
        XCTAssertTrue(element(app, "history-entry-actions").waitForExistence(timeout: 5))
        let title = app.staticTexts["Compaction"].firstMatch
        let time = app.staticTexts["Time"].firstMatch, entry = app.staticTexts["Entry"].firstMatch
        XCTAssertTrue(title.exists && time.exists && entry.exists, app.debugDescription)
        XCTAssertEqual(time.frame.minX, title.frame.minX, accuracy: 1, "Time follows the title text, not the icon")
        XCTAssertEqual(entry.frame.minX, title.frame.minX, accuracy: 1, "Entry follows the same text edge")
        XCTAssertEqual(app.staticTexts["h-6732"].frame.maxX, app.staticTexts["Current"].frame.maxX, accuracy: 1)
        keep("history-metadata-edges")
    }

    @MainActor func testProviderNamesAndGeometrySurviveUsageLoading() {
        let app = home(["-home-sheet-dashboard-workers", "-dashboard-view-home", "-home-dashboard-usage-delay"])
        defer { app.terminate() }
        let card = app.buttons["home-usage-card"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        let probe = app.staticTexts["fixture.home-usage-layout"]
        expectation(for: NSPredicate(format: "label CONTAINS 'openai-codex.name='"), evaluatedWith: probe)
        waitForExpectations(timeout: 3)
        XCTAssertEqual(card.label, "Loading account usage", "Names must already be drawn before usage resolves")
        let frames = usageFrames(probe.label)
        keep("provider-values-loading")
        expectation(for: NSPredicate(format: "label CONTAINS %@", "%"), evaluatedWith: card)
        waitForExpectations(timeout: 10)
        let resolved = usageFrames(probe.label)
        for id in ["anthropic.name", "openai-codex.name"] {
            XCTAssertNotNil(frames[id]); XCTAssertNotNil(resolved[id])
            if let before = frames[id], let after = resolved[id] {
                XCTAssertEqual(after.minY, before.minY, accuracy: 1.5, "Resolving usage must not move provider names")
                XCTAssertEqual(after.height, before.height, accuracy: 1)
            }
        }
        keep("provider-values-resolved")
    }

    @MainActor func testWorkspaceSurvivesCoverAndUncoverWithoutLoadingAgain() {
        let app = session(["-manage-session-review", "-workspace-capture-delay"]); defer { app.terminate() }
        let workspace = app.buttons["Workspace"]
        reveal(app, workspace)
        expectation(for: NSPredicate(format: "label CONTAINS 'Working tree clean'"), evaluatedWith: workspace)
        waitForExpectations(timeout: 5)
        let published = workspace.label
        tap(app, "manage-session-rename"); tap(app, "Cancel")
        // Native AX queries sample the delayed socket response interval; the old
        // monitor clears the value immediately, before its one-second read resolves.
        for _ in 0..<5 { XCTAssertEqual(workspace.label, published, "Closing a covering sheet must retain the published workspace") }
        keep("workspace-uncovered-retains-value")
    }

    @MainActor func testHomeModelCardRevertAndSelectionUseHomeScope() {
        let app = home(["-settings-scope-review"]); defer { app.terminate() }
        manageHome(app)
        let card = element(app, "home-model-summary")
        XCTAssertTrue(card.waitForExistence(timeout: 5), "The model card belongs directly below the usage summary")
        XCTAssertGreaterThanOrEqual(card.frame.minY, element(app, "home-context-summary").frame.maxY)
        XCTAssertTrue(card.staticTexts["Effort"].exists && card.staticTexts["Context Window"].exists)
        tap(app, "settings-row-model.ref_role_chat_-reset")
        XCTAssertTrue(card.staticTexts["Claude Haiku 5.5"].waitForExistence(timeout: 5), app.debugDescription)
        tap(app, "manage-model-switch")
        let opus = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Claude Opus 5.5'")).firstMatch
        XCTAssertTrue(opus.waitForExistence(timeout: 5)); opus.tap()
        XCTAssertTrue(card.staticTexts["Claude Opus 5.5"].waitForExistence(timeout: 5), "Home selection must persist through the existing Home-scoped settings RPC")
        tap(app, "home-manage-settings"); tap(app, "settings-section-model-open")
        XCTAssertFalse(element(app, "settings-row-model.ref_role_chat_").exists)
        XCTAssertTrue(element(app, "settings-row-model.queue_role_worker_").waitForExistence(timeout: 5), "Worker/delegation choices remain in Home Models")
        keep("home-model-write-and-remaining-workers")
    }

    @MainActor func testSessionModelCardUsesFencedWritesAndEffortRevert() {
        let app = session([]); defer { app.terminate() }
        tap(app, "Release terminal settlement")
        let card = element(app, "session-model-summary")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(card.staticTexts["Effort"].exists && card.staticTexts["Context Window"].exists)
        tap(app, "settings-row-model.thinking_role_chat_-reset")
        XCTAssertTrue(card.staticTexts["High"].waitForExistence(timeout: 5), "Revert must use the fenced session unset, not a model picker")
        tap(app, "manage-model-switch")
        let alternative = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Alternative Model'")).firstMatch
        XCTAssertTrue(alternative.waitForExistence(timeout: 5)); alternative.tap()
        XCTAssertTrue(card.staticTexts["Alternative Model"].waitForExistence(timeout: 10), "Only the acknowledged fenced session choice is published")
        XCTAssertTrue(app.staticTexts["Model requests: 1"].exists, "Preview must not count as a mutation")
        keep("session-model-fenced-write-and-effort-revert")
    }

    @MainActor func testSessionSettingsKeepsWorkerOverridesAndTrustReachable() {
        let app = session(["-manage-session-review"]); defer { app.terminate() }
        tap(app, "chat-settings-link")
        XCTAssertTrue(element(app, "session-settings-content").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["settings-section-model-open"].exists, "Session Settings no longer has a Models sheet")
        XCTAssertFalse(app.staticTexts["Agent"].exists || app.staticTexts["Tools & Extensions"].exists)
        XCTAssertTrue(app.buttons["settings-section-context-open"].exists && app.buttons["settings-section-tools-open"].exists)
        XCTAssertTrue(app.buttons["project-settings-trust"].exists)
        tap(app, "settings-section-advanced-open")
        XCTAssertTrue(element(app, "settings-row-model.queue_role_background_").waitForExistence(timeout: 5), "Moving chat controls must not strand worker overrides")
        close(app); tap(app, "project-settings-trust")
        XCTAssertTrue(app.navigationBars.staticTexts["Project Trust"].waitForExistence(timeout: 5), app.debugDescription)
        keep("session-settings-worker-and-trust-routes")
    }

    @MainActor private func home(_ extra: [String]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"] + extra
        app.launch(); XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10)); return app
    }
    @MainActor private func session(_ extra: [String]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-tron-session-configuration-fixture"] + extra
        app.launch(); tap(app, "Stop session"); return app
    }
    @MainActor private func manageHome(_ app: XCUIApplication) { tap(app, "home-pinned-row"); tap(app, "session-context-button"); XCTAssertTrue(element(app, "home-manage-state").waitForExistence(timeout: 5)) }
    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    @MainActor private func reveal(_ app: XCUIApplication, _ item: XCUIElement) { for _ in 0..<10 where !item.isHittable { app.swipeUp() } }
    @MainActor private func tap(_ app: XCUIApplication, _ id: String) {
        let item = element(app, id); XCTAssertTrue(item.waitForExistence(timeout: 5), "Missing \(id): \(app.debugDescription)"); reveal(app, item); item.tap()
    }
    private func usageFrames(_ label: String) -> [String: CGRect] {
        Dictionary(uniqueKeysWithValues: label.split(separator: ";").compactMap { entry in
            let pair = entry.split(separator: "="); guard pair.count == 2 else { return nil }
            let values = pair[1].split(separator: ",").compactMap { Double($0) }; guard values.count == 4 else { return nil }
            return (String(pair[0]), CGRect(x: values[0], y: values[1], width: values[2], height: values[3]))
        })
    }
    @MainActor private func close(_ app: XCUIApplication) { app.buttons.matching(NSPredicate(format: "label == 'Done'")).allElementsBoundByIndex.last(where: \.isHittable)?.tap() }
    @MainActor private func keep(_ name: String) { let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
}
