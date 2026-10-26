import Foundation
import XCTest

/// #2010: production navigation and the shared queue draft cross a real socket
/// into the fixture Gateway's canonical store. No user settings are touched.
extension RealGatewayPairAndChatUITests {
    @MainActor
    func testAgentBehaviorQueuesSaveReopenAndResetLight() throws {
        try agentBehaviorQueues(appearance: "light")
    }

    @MainActor
    func testAgentBehaviorQueuesSaveReopenAndResetDark() throws {
        try agentBehaviorQueues(appearance: "dark")
    }

    @MainActor
    private func agentBehaviorQueues(appearance: String) throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let agent = URL(fileURLWithPath: try XCTUnwrap(fixture.agentDirectory))
        let store = agent.deletingLastPathComponent().appendingPathComponent("tron/gateway/settings/gateway.json")
        // Seed only this fresh fixture's retired compaction override, so review
        // captures show its surviving inspector in the consolidated sheet too.
        let settingsFile = agent.appendingPathComponent("settings.json")
        var settings = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsFile)) as! [String: Any]
        settings["compaction"] = ["reserveTokens": 24_576]
        try JSONSerialization.data(withJSONObject: settings).write(to: settingsFile)
        func saved(_ role: String) -> [String]? {
            let document = (try? JSONSerialization.jsonObject(with: Data(contentsOf: store))) as? [String: Any]
            return (document?["modelQueues"] as? [String: Any])?[role] as? [String]
        }
        do {
            let app = launchApp(additionalArguments: ["-appearanceMode", appearance])
            defer { app.terminate() }
            open(fixture.invitationLink())
            completeFirstRunSetup(app, inWorkspace: fixture.workspace)
            XCTAssertTrue(waitForHittable(app.buttons["dashboard.menu"], timeout: 90), app.debugDescription)
            createSession(app, inWorkspace: fixture.workspace)
            let gear = app.navigationBars.buttons["Settings"]
            XCTAssertTrue(gear.waitForExistence(timeout: 30), app.debugDescription)
            gear.tap()
            XCTAssertTrue(app.buttons["settings-done"].waitForExistence(timeout: 30), app.debugDescription)
            expandAgentSheet(app, title: "Global Settings")
            keepScreenshot(app, name: "2010-global-root-top-\(appearance)")
            let agentBehavior = app.buttons["settings-link-Agent Behavior"]
            revealBelowNavigationBar(app, agentBehavior)
            XCTAssertTrue(agentBehavior.isHittable, app.debugDescription)
            for _ in 0..<3 where agentBehavior.frame.maxY > app.windows.firstMatch.frame.maxY - 120 { app.swipeUp() }
            keepScreenshot(app, name: "2010-global-root-agent-tools-\(appearance)")
            agentBehavior.tap()
            XCTAssertTrue(app.navigationBars.staticTexts["Agent Behavior"].waitForExistence(timeout: 30), app.debugDescription)
            expandAgentSheet(app, title: "Agent Behavior")
            keepScreenshot(app, name: "2010-agent-settings-top-\(appearance)")
            for (role, label) in [("worker", "Worker models"), ("subagent", "Subagent models"), ("background", "Background models")] {
                // Real resolutions include the fixed role qualifier in the row identity;
                // synthetic fixtures may omit that suffix. Address the owning row, not its reset child.
                let row = app.descendants(matching: .any).matching(NSPredicate(
                    format: "identifier BEGINSWITH %@ AND NOT identifier ENDSWITH '-reset'",
                    "settings-row-model.queue_role_\(role)_")).firstMatch
                revealBelowNavigationBar(app, row)
                let edit = row.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label != 'Reset'", label)).firstMatch
                XCTAssertTrue(edit.waitForExistence(timeout: 15), "Queue has no editor: \(row.debugDescription)")
                edit.tap()
                XCTAssertTrue(app.navigationBars.staticTexts[label].waitForExistence(timeout: 15), app.debugDescription)
                expandAgentSheet(app, title: label)
                keepScreenshot(app, name: "2010-queue-\(role)-empty-\(appearance)")
                addQueueModel(app, named: "Tron E2E Model")
                addQueueModel(app, named: "Tron E2E Alternate")
                let earlier = app.buttons["Move tron-e2e/e2e-alternate earlier"]
                XCTAssertTrue(earlier.waitForExistence(timeout: 15), app.debugDescription)
                earlier.tap()
                keepScreenshot(app, name: "2010-queue-\(role)-ordered-\(appearance)")
                app.buttons["Save"].tap()
                XCTAssertTrue(waitUntil(timeout: 15) { saved(role) == ["tron-e2e/e2e-alternate", "tron-e2e/e2e-model"] }, "Ordered draft did not reach the canonical Gateway store")
                revealBelowNavigationBar(app, row)
                edit.tap()
                XCTAssertTrue(app.buttons["Remove tron-e2e/e2e-model"].waitForExistence(timeout: 15), app.debugDescription)
                app.buttons["Remove tron-e2e/e2e-model"].tap()
                app.buttons["Save"].tap()
                XCTAssertTrue(waitUntil(timeout: 15) { saved(role) == ["tron-e2e/e2e-alternate"] })
                revealBelowNavigationBar(app, row)
                edit.tap()
                XCTAssertTrue(app.buttons["Remove tron-e2e/e2e-alternate"].waitForExistence(timeout: 15), app.debugDescription)
                app.buttons["Remove tron-e2e/e2e-alternate"].tap()
                app.buttons["Save"].tap()
                XCTAssertTrue(waitUntil(timeout: 15) { saved(role) == [] }, "Empty is an explicit queue choice, not Reset")
                revealBelowNavigationBar(app, row)
                let reset = row.buttons.matching(NSPredicate(format: "identifier ENDSWITH '-reset'")).firstMatch
                XCTAssertTrue(reset.waitForExistence(timeout: 15), app.debugDescription)
                reset.tap()
                XCTAssertTrue(waitUntil(timeout: 15) { saved(role) == nil }, "Reset must remove, not copy, the inherited value")
            }
            let trust = app.descendants(matching: .any)["settings-row-permissions.defaultProjectTrust"]
            revealBelowNavigationBar(app, trust)
            XCTAssertTrue(trust.exists, app.debugDescription)
            keepScreenshot(app, name: "2010-agent-settings-trust-\(appearance)")
            for _ in 0..<5 { app.swipeUp() }
            keepScreenshot(app, name: "2010-agent-settings-more-\(appearance)")
            dismissTopSheet(app)
            let changes = app.buttons["Changes"]
            revealBelowNavigationBar(app, changes)
            changes.tap()
            let entry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'settings-change-' AND label BEGINSWITH 'Background models,'")).firstMatch
            XCTAssertTrue(entry.waitForExistence(timeout: 30), app.debugDescription)
            entry.tap()
            XCTAssertTrue(app.staticTexts["Before"].waitForExistence(timeout: 15), app.debugDescription)
            XCTAssertTrue(app.staticTexts["After"].exists, app.debugDescription)
            let undo = app.buttons["Undo"]
            revealBelowNavigationBar(app, undo)
            XCTAssertTrue(undo.waitForExistence(timeout: 15), app.debugDescription)
            undo.tap()
            let confirm = app.buttons["Undo change"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 15), app.debugDescription)
            confirm.tap()
            XCTAssertTrue(waitUntil(timeout: 15) { saved("background") == [] }, "Changes Undo restores the explicit empty queue through the receipt owner")
            keepScreenshot(app, name: "2010-agent-behavior-changes-\(appearance)")
            app.terminate()
        }
    }

    @MainActor
    func testHomeQueueEditorUsesHomeScopeAndKeepsModelsRoute() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let agent = URL(fileURLWithPath: try XCTUnwrap(fixture.agentDirectory))
        let tron = agent.deletingLastPathComponent().appendingPathComponent("tron/gateway")
        let homeFile = tron.appendingPathComponent("home/profile.json")
        let globalFile = tron.appendingPathComponent("settings/gateway.json")
        func queue(_ file: URL, field: String) -> [String]? {
            let document = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any]
            return (document?[field] as? [String: Any])?["worker"] as? [String]
        }
        let app = launchApp()
        defer { app.terminate() }
        open(fixture.invitationLink())
        completeFirstRunSetup(app, inWorkspace: fixture.workspace)
        let home = app.buttons["home-pinned-row"]
        XCTAssertTrue(waitForEnabled(home, timeout: 90), app.debugDescription)
        home.tap()
        let ring = app.buttons["session-context-button"]
        XCTAssertTrue(waitForEnabled(ring, timeout: 60), app.debugDescription)
        ring.tap()
        let settings = app.buttons["home-manage-settings"]
        revealBelowNavigationBar(app, settings)
        XCTAssertTrue(settings.waitForExistence(timeout: 30), app.debugDescription)
        settings.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Home Settings"].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(app.buttons["settings-link-Agent Behavior"].exists, "Global consolidation must not replace Home's routes")
        let models = app.buttons["settings-section-model-open"]
        revealBelowNavigationBar(app, models)
        models.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Models"].waitForExistence(timeout: 30), app.debugDescription)
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'settings-row-model.queue_role_worker_' AND NOT identifier ENDSWITH '-reset'")).firstMatch
        revealBelowNavigationBar(app, row)
        let edit = row.buttons.matching(NSPredicate(format: "label == 'Worker models' AND NOT identifier ENDSWITH '-reset'")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 15), app.debugDescription)
        edit.tap()
        addQueueModel(app, named: "Tron E2E Alternate")
        app.buttons["Save"].tap()
        XCTAssertTrue(waitUntil(timeout: 15) { queue(homeFile, field: "modelQueue") == ["tron-e2e/e2e-alternate"] }, "Home Save must reach the canonical Home profile")
        XCTAssertNil(queue(globalFile, field: "modelQueues"), "A Home edit must not change Global")
        revealBelowNavigationBar(app, row)
        edit.tap()
        XCTAssertTrue(app.buttons["Remove tron-e2e/e2e-alternate"].waitForExistence(timeout: 15), app.debugDescription)
        dismissTopSheet(app)
        let revert = row.buttons.matching(NSPredicate(format: "identifier ENDSWITH '-reset'")).firstMatch
        revealBelowNavigationBar(app, revert)
        revert.tap()
        XCTAssertTrue(waitUntil(timeout: 15) { queue(homeFile, field: "modelQueue") == nil }, "Home Revert must remove its override")
        XCTAssertNil(queue(globalFile, field: "modelQueues"))
        keepScreenshot(app, name: "2010-home-queue-scope-and-reopen")
    }

    @MainActor
    func openAgentBehavior(_ app: XCUIApplication) {
        let link = app.buttons["settings-link-Agent Behavior"]
        revealBelowNavigationBar(app, link)
        XCTAssertTrue(link.waitForExistence(timeout: 30), app.debugDescription)
        link.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Agent Behavior"].waitForExistence(timeout: 30), app.debugDescription)
        expandAgentSheet(app, title: "Agent Behavior")
    }

    @MainActor
    private func expandAgentSheet(_ app: XCUIApplication, title: String) {
        let heading = app.navigationBars.staticTexts[title].firstMatch
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        for _ in 0..<3 where heading.frame.minY > 120 {
            origin.withOffset(CGVector(dx: 60, dy: heading.frame.midY))
                .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: 60, dy: 20)))
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "frame.minY < 120"), object: heading)], timeout: 2)
        }
    }

    @MainActor
    private func addQueueModel(_ app: XCUIApplication, named name: String) {
        let add = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Add model'")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 15), app.debugDescription)
        // The glass row also projects as a Button in AX; its trailing Choose
        // button owns navigation, not the non-interactive title area.
        let choose = add.buttons.matching(NSPredicate(format: "label == 'Add model'")).firstMatch
        choose.tap()
        // Search expands provider groups and avoids matching a covered Thinking
        // row named “For <model>” in the sheet below this picker.
        let search = app.buttons["Search models"]
        XCTAssertTrue(search.waitForExistence(timeout: 30), app.debugDescription)
        search.tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15), app.debugDescription)
        field.typeText(name)
        let model = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@ AND label CONTAINS 'tron-e2e/'", name)).firstMatch
        XCTAssertTrue(model.waitForExistence(timeout: 30), app.debugDescription)
        model.tap()
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 15), app.debugDescription)
    }
}
