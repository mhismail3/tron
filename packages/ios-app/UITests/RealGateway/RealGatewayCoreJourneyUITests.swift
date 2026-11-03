import Foundation
import XCTest

/// Core-journey proofs across the real UI, socket and Gateway (#2142): the
/// production scene paired by invitation link against the fixture Gateway, whose
/// faux model is the only scripted party. Each oracle is something the user sees
/// or the Gateway's canonical store, never a hosted projection.
extension RealGatewayPairAndChatUITests {
    /// #2230: one streamed reply is rendered exactly once, and stays exactly once
    /// after the app leaves and returns (the transport is retired and reopened).
    @MainActor
    func testStreamedReplyAppearsExactlyOnceAcrossReconnect() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let app = launchApp()
        defer { app.terminate() }
        open(fixture.invitationLink())
        completeFirstRunSetup(app, inWorkspace: fixture.workspace)
        XCTAssertTrue(waitForHittable(app.buttons["dashboard.menu"], timeout: 90), app.debugDescription)
        createSession(app, inWorkspace: fixture.workspace)
        let prompt = "Exactly-once reply journey."
        sendJourneyPrompt(app, prompt)
        // The fixture's first ordinary reply streams; its last words mark completion.
        let completion = "Detached response complete"
        // Each assistant message renders one selectable text view (its identifier);
        // the prompt is counted outside the navigation title the chat derives from it.
        let reply = app.textViews.matching(identifier: "chat.assistant.selectable-text")
            .matching(NSPredicate(format: "label CONTAINS %@", completion))
        XCTAssertTrue(reply.firstMatch.waitForExistence(timeout: 180), app.debugDescription)
        let sentPredicate = NSPredicate(format: "label == %@", prompt)
        func sentCount() -> Int { app.staticTexts.matching(sentPredicate).count - app.navigationBars.staticTexts.matching(sentPredicate).count }
        XCTAssertEqual(reply.count, 1, "the completed reply must be rendered once: \(app.debugDescription)")
        XCTAssertEqual(sentCount(), 1, "the prompt must be rendered once: \(app.debugDescription)")
        keepScreenshot(app, name: "2230-reply-exactly-once")
        // Backgrounding retires the transport; the foreground reopens the session
        // from the Gateway's authoritative snapshot.
        returnFromAnotherApp(app)
        XCTAssertTrue(waitForEnabled(app.buttons["session-context-button"], timeout: 90), app.debugDescription)
        XCTAssertTrue(reply.firstMatch.waitForExistence(timeout: 60), app.debugDescription)
        XCTAssertEqual(reply.count, 1, "the reconnected snapshot must not duplicate the reply: \(app.debugDescription)")
        XCTAssertEqual(sentCount(), 1, "the reconnected snapshot must not duplicate the prompt: \(app.debugDescription)")
        keepScreenshot(app, name: "2230-reply-exactly-once-after-reconnect")
    }

    /// #2233: a native Session model change reaches the next prompt the fixture
    /// model serves, another chat stays on the Global model, and Undo through
    /// Changes restores the Global model for the next prompt.
    @MainActor
    func testSessionModelChangeReachesNextPromptAndUndoRestoresIt() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let app = launchApp()
        defer { app.terminate() }
        open(fixture.invitationLink())
        completeFirstRunSetup(app, inWorkspace: fixture.workspace)
        XCTAssertTrue(waitForHittable(app.buttons["dashboard.menu"], timeout: 90), app.debugDescription)
        createSession(app, inWorkspace: fixture.workspace)
        func served(_ model: String) -> XCUIElementQuery {
            app.textViews.matching(identifier: "chat.assistant.selectable-text")
                .matching(NSPredicate(format: "label CONTAINS %@", "Model probe answered by \(model)."))
        }
        func probe(_ label: String, expecting model: String, count: Int) {
            sendJourneyPrompt(app, "MODEL-PROBE-JOURNEY \(label)")
            XCTAssertTrue(waitUntil(timeout: 120) { served(model).count == count },
                          "prompt \(label) must be served by \(model): \(app.debugDescription)")
        }
        probe("one", expecting: "e2e-model", count: 1)

        let manage = app.buttons["session-context-button"]
        XCTAssertTrue(waitForEnabled(manage, timeout: 60), app.debugDescription)
        manage.tap()
        let card = app.descendants(matching: .any)["session-model-summary"]
        XCTAssertTrue(card.waitForExistence(timeout: 30), app.debugDescription)
        let switchModel = app.buttons["manage-model-switch"]
        XCTAssertTrue(waitForEnabled(switchModel, timeout: 30), app.debugDescription)
        switchModel.tap()
        // Search expands the provider group and brings the row into the sheet.
        let search = app.buttons["Search models"]
        XCTAssertTrue(search.waitForExistence(timeout: 30), app.debugDescription)
        search.tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15), app.debugDescription)
        field.typeText("Alternate")
        let alternate = app.buttons.matching(NSPredicate(format: "label CONTAINS 'tron-e2e/e2e-alternate'")).firstMatch
        XCTAssertTrue(waitForHittable(alternate, timeout: 30), app.debugDescription)
        alternate.tap()
        XCTAssertTrue(card.staticTexts.matching(NSPredicate(format: "label ==[c] 'Tron E2E Alternate'")).firstMatch.waitForExistence(timeout: 30),
                      "only the acknowledged Session choice is shown: \(app.debugDescription)")
        keepScreenshot(app, name: "2233-session-model-changed")
        dismissTopSheet(app)
        probe("two", expecting: "e2e-alternate", count: 1)
        XCTAssertEqual(served("e2e-model").count, 1, "the earlier reply keeps its model")

        // Another chat reads Global, not this chat's Session override.
        app.buttons["Back"].tap()
        let changedRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "session-row-")).firstMatch
        XCTAssertTrue(waitForHittable(changedRow, timeout: 60), app.debugDescription)
        let changedRowID = changedRow.identifier
        createSession(app, inWorkspace: fixture.workspace)
        probe("other", expecting: "e2e-model", count: 1)
        XCTAssertEqual(served("e2e-alternate").count, 0, "the other chat must not run the Session override")

        // Return to the changed chat and undo its recorded change through Global
        // Settings → Changes; the session-scope Undo is fenced to that open chat.
        app.buttons["Back"].tap()
        let changedChat = app.buttons[changedRowID]
        XCTAssertTrue(waitForHittable(changedChat, timeout: 60), app.debugDescription)
        changedChat.tap()
        XCTAssertTrue(served("e2e-alternate").firstMatch.waitForExistence(timeout: 60), app.debugDescription)
        XCTAssertTrue(waitForEnabled(app.buttons["session-context-button"], timeout: 60), app.debugDescription)
        let gear = app.navigationBars.buttons["Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 30), app.debugDescription)
        gear.tap()
        let changes = app.buttons["Changes"]
        XCTAssertTrue(changes.waitForExistence(timeout: 30), app.debugDescription)
        changes.tap()
        let entry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'settings-change-' AND label BEGINSWITH 'Model,'")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 30), app.debugDescription)
        entry.tap()
        XCTAssertTrue(app.staticTexts["Before"].waitForExistence(timeout: 15), app.debugDescription)
        let undo = app.buttons["Undo"]
        revealBelowNavigationBar(app, undo)
        XCTAssertTrue(undo.waitForExistence(timeout: 15), app.debugDescription)
        undo.tap()
        let confirm = app.buttons["Undo change"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15), app.debugDescription)
        confirm.tap()
        // A successful Undo closes the change's detail; a refusal keeps it with its error.
        XCTAssertTrue(waitUntil(timeout: 60) { !app.staticTexts["Before"].exists }, "Undo did not complete: \(app.debugDescription)")
        keepScreenshot(app, name: "2233-session-model-undone")
        let tronHome = URL(fileURLWithPath: try XCTUnwrap(fixture.agentDirectory)).deletingLastPathComponent().appendingPathComponent("tron")
        let sessionChanges = settingsHistory(tronHome, key: "model.ref[role=chat]").filter { ($0["target"] as? [String: Any])?["kind"] as? String == "session" }
        XCTAssertEqual(sessionChanges.count, 2, "one Session change and its one Undo: \(sessionChanges)")
        XCTAssertEqual(sessionChanges.last?["undoOf"] as? String, sessionChanges.first?["changeId"] as? String)
        XCTAssertEqual(sessionChanges.last?["status"] as? String, "applied")
        dismissTopSheet(app) // Changes
        dismissTopSheet(app) // Global Settings
        XCTAssertTrue(waitForHittable(app.buttons["Back"], timeout: 30), app.debugDescription)
        probe("three", expecting: "e2e-model", count: 2)
        XCTAssertEqual(served("e2e-alternate").count, 1, "Undo must not rewrite the earlier reply")
    }

    /// #2232: Home's model asks for a task-budget raise, which needs the shared
    /// change card. Declining applies nothing; a second card approved with two
    /// quick taps applies once. The canonical Home store and the settings audit
    /// are read directly from the fixture Gateway.
    @MainActor
    func testHomeSettingsCardDeclineAppliesNothingAndDoubleApproveAppliesOnce() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let tronHome = URL(fileURLWithPath: try XCTUnwrap(fixture.agentDirectory)).deletingLastPathComponent().appendingPathComponent("tron")
        func budget() -> Int? {
            let document = (try? JSONSerialization.jsonObject(with: Data(contentsOf: tronHome.appendingPathComponent("gateway/home/profile.json")))) as? [String: Any]
            return ((document?["budget"] as? [String: Any])?["task"] as? [String: Any])?["outputTokens"] as? Int
        }
        func budgetHistory() -> [[String: Any]] { settingsHistory(tronHome, key: "permissions.budget.task") }
        // The fixture seeded 100 through the Home-scoped settings RPC.
        XCTAssertEqual(budget(), 100)
        let seeded = budgetHistory()
        XCTAssertEqual(seeded.count, 1, "\(seeded)")

        let app = launchApp()
        defer { app.terminate() }
        open(fixture.invitationLink())
        completeFirstRunSetup(app, inWorkspace: fixture.workspace)
        let home = app.buttons["home-pinned-row"]
        XCTAssertTrue(waitForHittable(home, timeout: 90), app.debugDescription)
        home.tap()
        XCTAssertTrue(waitForEnabled(app.buttons["session-context-button"], timeout: 60), app.debugDescription)

        // A raise to 300 presents the card; Cancel declines it.
        sendJourneyPrompt(app, "SETTINGS-CARD-JOURNEY 300")
        let card = app.descendants(matching: .any)["change-review-card"]
        XCTAssertTrue(card.waitForExistence(timeout: 120), app.debugDescription)
        XCTAssertEqual(budget(), 100, "presenting the card must not apply it")
        keepScreenshot(app, name: "2232-home-budget-card-decline")
        let cancel = app.buttons["change-review-cancel"]
        XCTAssertTrue(waitForHittable(cancel, timeout: 15), app.debugDescription)
        cancel.tap()
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "label BEGINSWITH 'Settings card journey result:'")).firstMatch
            .waitForExistence(timeout: 120), app.debugDescription)
        XCTAssertFalse(card.exists, "a declined card must close")
        XCTAssertEqual(budget(), 100, "a declined card must apply nothing")
        XCTAssertEqual(budgetHistory().count, seeded.count, "a declined card must record no change")

        // A raise to 200 presents a new card; two quick Approve taps apply once.
        sendJourneyPrompt(app, "SETTINGS-CARD-JOURNEY 200")
        XCTAssertTrue(card.waitForExistence(timeout: 120), app.debugDescription)
        let approve = app.buttons["change-review-approve"]
        XCTAssertTrue(waitForHittable(approve, timeout: 15), app.debugDescription)
        approve.tap()
        if approve.exists && approve.isHittable { approve.tap() }
        XCTAssertTrue(waitUntil(timeout: 60) { budget() == 200 }, "the approved raise never reached the Home store")
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "label BEGINSWITH 'Settings card journey result:'")).element(boundBy: 1)
            .waitForExistence(timeout: 120), app.debugDescription)
        let applied = budgetHistory().dropFirst(seeded.count)
        XCTAssertEqual(applied.count, 1, "two approve taps must record one change: \(Array(applied))")
        XCTAssertEqual(applied.first?["status"] as? String, "applied")
        XCTAssertEqual((applied.first?["after"] as? [String: Any])?["outputTokens"] as? Int, 200)
        XCTAssertFalse(card.exists, "an approved card must close")
        keepScreenshot(app, name: "2232-home-budget-card-approved-once")
    }

    /// The fixture Gateway's canonical settings audit for one key, oldest first.
    private func settingsHistory(_ tronHome: URL, key: String) -> [[String: Any]] {
        let directory = tronHome.appendingPathComponent("gateway/settings/changes")
        let segments = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return segments.flatMap { segment in
            ((try? String(contentsOf: segment, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
        }.filter { $0["key"] as? String == key }
    }

    @MainActor
    private func sendJourneyPrompt(_ app: XCUIApplication, _ text: String) {
        let composer = app.textViews["Message input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 60), app.debugDescription)
        composer.tap()
        composer.typeText(text)
        let send = app.buttons["Send message"]
        XCTAssertTrue(send.waitForExistence(timeout: 60), "the send control never appeared: \(app.debugDescription)")
        XCTAssertTrue(waitForEnabled(send, timeout: 60), "the composer never accepted the prompt: \(app.debugDescription)")
        send.tap()
    }
}
