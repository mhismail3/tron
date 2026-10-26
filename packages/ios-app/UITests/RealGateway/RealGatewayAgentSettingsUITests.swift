import Foundation
import XCTest

/// #2010: production navigation and the shared queue draft cross a real socket
/// into the fixture Gateway's canonical store. No user settings are touched.
extension RealGatewayPairAndChatUITests {
    @MainActor
    func testAgentSettingsQueuesSaveReopenAndResetInLightAndDark() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let tronHome = try XCTUnwrap(ProcessInfo.processInfo.environment["TRON_E2E_TRON_HOME"])
        let store = URL(fileURLWithPath: tronHome).appendingPathComponent("gateway/settings/gateway.json")
        func saved(_ role: String) -> [String]? {
            let document = (try? JSONSerialization.jsonObject(with: Data(contentsOf: store))) as? [String: Any]
            return (document?["modelQueues"] as? [String: Any])?[role] as? [String]
        }
        for appearance in ["light", "dark"] {
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
            let agentSettings = app.buttons["settings-link-Agent Settings"]
            revealBelowNavigationBar(app, agentSettings)
            XCTAssertTrue(agentSettings.isHittable, app.debugDescription)
            keepScreenshot(app, name: "2010-global-root-system-\(appearance)")
            agentSettings.tap()
            XCTAssertTrue(app.navigationBars.staticTexts["Agent Settings"].waitForExistence(timeout: 30), app.debugDescription)
            expandAgentSheet(app, title: "Agent Settings")
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
            app.terminate()
        }
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
        add.tap()
        let model = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        XCTAssertTrue(model.waitForExistence(timeout: 30), app.debugDescription)
        model.tap()
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 15), app.debugDescription)
    }
}
