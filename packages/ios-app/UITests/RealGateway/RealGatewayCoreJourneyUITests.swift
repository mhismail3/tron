import Foundation
import XCTest

extension RealGatewayPairAndChatUITests {
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
        let completion = "Detached response complete"
        let reply = app.textViews.matching(identifier: "chat.assistant.selectable-text")
            .descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", completion))
        XCTAssertTrue(reply.firstMatch.waitForExistence(timeout: 180), app.debugDescription)
        let sentPredicate = NSPredicate(format: "label == %@", prompt)
        func sentCount() -> Int { app.staticTexts.matching(sentPredicate).count - app.navigationBars.staticTexts.matching(sentPredicate).count }
        XCTAssertEqual(reply.count, 1, "the completed reply must be rendered once: \(app.debugDescription)")
        XCTAssertEqual(sentCount(), 1, "the prompt must be rendered once: \(app.debugDescription)")
        keepScreenshot(app, name: "2230-reply-exactly-once")
        app.buttons["Back"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "session-row-")).firstMatch
        XCTAssertTrue(waitForHittable(row, timeout: 60), app.debugDescription)
        let rowID = row.identifier
        returnFromAnotherApp(app)
        let reopened = app.buttons[rowID]
        XCTAssertTrue(waitForHittable(reopened, timeout: 90), app.debugDescription)
        reopened.tap()
        XCTAssertTrue(reply.firstMatch.waitForExistence(timeout: 60), app.debugDescription)
        XCTAssertTrue(waitForEnabled(app.buttons["session-context-button"], timeout: 90), app.debugDescription)
        XCTAssertEqual(reply.count, 1, "the reopened snapshot must not duplicate the reply: \(app.debugDescription)")
        XCTAssertEqual(sentCount(), 1, "the reopened snapshot must not duplicate the prompt: \(app.debugDescription)")
        keepScreenshot(app, name: "2230-reply-exactly-once-after-reconnect")
    }

    @MainActor
    func testHomeSettingsCardDeclineAppliesNothingAndDoubleApproveAppliesOnce() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let tronHome = fixture.tronHome
        func budget() -> Int? {
            let document = (try? JSONSerialization.jsonObject(with: Data(contentsOf: tronHome.appendingPathComponent("state/home/profile.json")))) as? [String: Any]
            return ((document?["budget"] as? [String: Any])?["task"] as? [String: Any])?["outputTokens"] as? Int
        }
        func budgetHistory() -> [[String: Any]] { settingsHistory(tronHome, key: "permissions.budget.task") }
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

        sendJourneyPrompt(app, "SETTINGS-CARD-JOURNEY 200")
        XCTAssertTrue(card.waitForExistence(timeout: 120), app.debugDescription)
        let approve = app.buttons["change-review-approve"]
        XCTAssertTrue(waitForHittable(approve, timeout: 15), app.debugDescription)
        approve.doubleTap()
        XCTAssertTrue(waitUntil(timeout: 60) { budget() == 200 }, "the approved raise never reached the Home store")
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "label BEGINSWITH 'Settings card journey result:'")).element(boundBy: 1)
            .waitForExistence(timeout: 120), app.debugDescription)
        let applied = budgetHistory().dropFirst(seeded.count)
        XCTAssertEqual(applied.count, 1, "two approve taps must record one change: \(Array(applied))")
        XCTAssertEqual(applied.first?["status"] as? String, "applied")
        XCTAssertEqual((applied.first?["after"] as? [String: Any])?["outputTokens"] as? Int, 200)
        XCTAssertFalse(card.exists, "an approved card must close")
        XCTAssertFalse(app.descendants(matching: .any)["in-app-notice-card"].exists, "the double tap must not surface a second answer's error: \(app.debugDescription)")
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Could not submit'")).count, 0)
        keepScreenshot(app, name: "2232-home-budget-card-approved-once")
    }

    private func settingsHistory(_ tronHome: URL, key: String) -> [[String: Any]] {
        let directory = tronHome.appendingPathComponent("state/settings/changes")
        let segments = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return segments.flatMap { segment in
            ((try? String(contentsOf: segment, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
        }.filter { $0["key"] as? String == key }
    }

    @MainActor
    func testGatewayRestartWaitsForLiveWorkThenRestartsIdleAndReconnects() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let agentDirectory = try XCTUnwrap(fixture.agentDirectory)
        let goFile = URL(fileURLWithPath: agentDirectory).deletingLastPathComponent()
            .appending(path: "restart-journey-\(UUID().uuidString).go")
        defer { try? FileManager.default.removeItem(at: goFile) }
        let app = launchApp()
        defer { app.terminate() }
        open(fixture.invitationLink())
        completeFirstRunSetup(app, inWorkspace: fixture.workspace)
        XCTAssertTrue(waitForHittable(app.buttons["dashboard.menu"], timeout: 90), app.debugDescription)
        createSession(app, inWorkspace: fixture.workspace)
        sendJourneyPrompt(app, "GATEWAY-RESTART-JOURNEY \(goFile.path)")
        let gear = app.navigationBars.buttons["Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 30), app.debugDescription)
        gear.tap()
        let link = app.buttons["settings-link-Connections"]
        for _ in 0..<20 where !link.isHittable { app.swipeDown() }
        link.tap()
        let details = app.buttons["Details for Tron iOS E2E"]
        XCTAssertTrue(waitForHittable(details, timeout: 30), app.debugDescription)
        details.tap()

        let connected = app.descendants(matching: .any)["Connection status: Connected"]
        func assertNotice(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
            let cards = app.descendants(matching: .any).matching(identifier: "in-app-notice-card")
            var seen: [String] = []
            let shown = waitUntil(timeout: 30) {
                for label in cards.allElementsBoundByIndex.map(\.label) where !seen.contains(label) { seen.append(label) }
                return seen.contains(text)
            }
            XCTAssertTrue(shown, "expected notice \"\(text)\"; saw \(seen)", file: file, line: line)
        }
        func confirmRestart() {
            let restart = app.buttons["Restart"]
            for _ in 0..<8 where !restart.isHittable { app.swipeUp() }
            XCTAssertTrue(waitForEnabled(restart, timeout: 30), "a supervised Gateway admits Restart: \(app.debugDescription)")
            restart.tap()
            let confirm = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "confirmation-primary-")).firstMatch
            XCTAssertTrue(waitForHittable(confirm, timeout: 15), app.debugDescription)
            confirm.tap()
        }

        confirmRestart()
        assertNotice("Gateway restart scheduled after 1 accepted operation finishes.")
        keepScreenshot(app, name: "2366-restart-scheduled")
        try Data().write(to: goFile)
        try setProxyMode(fixture, mode: "respawn-exited-gateway", timeout: 75)
        XCTAssertTrue(connected.waitForExistence(timeout: 90), "the drained restart reconnects: \(app.debugDescription)")
        let sessions = URL(fileURLWithPath: agentDirectory).appending(path: "sessions")
        func heldTurnFinished() -> Bool {
            let files = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" } ?? []
            return files.contains { (try? String(contentsOf: $0, encoding: .utf8))?.contains("Restart journey turn finished.") == true }
        }
        XCTAssertTrue(waitUntil(timeout: 60, heldTurnFinished), "the restart did not let the held turn finish")

        confirmRestart()
        assertNotice("Gateway is restarting. Tron will reconnect automatically.")
        XCTAssertTrue(app.descendants(matching: .any)["Connection status: Restarting"].waitForExistence(timeout: 15),
                      app.debugDescription)
        keepScreenshot(app, name: "2366-restart-idle")
        try setProxyMode(fixture, mode: "respawn-exited-gateway", timeout: 75)
        XCTAssertTrue(connected.waitForExistence(timeout: 90), "the idle restart reconnects: \(app.debugDescription)")
        keepScreenshot(app, name: "2366-restart-reconnected")
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
