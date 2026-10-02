import XCTest

final class TronNewSessionUITests: XCTestCase {
    @MainActor func testSourceControlDraftSurvivesChildDoneAndBackground() {
        continueAfterFailure = false
        let app = launch("draft"); defer { app.terminate() }
        chooseBranch(app)
        app.buttons["Done"].tap()
        XCTAssertTrue(wait(app.buttons["new-session-card.Source Control"], "label CONTAINS 'fixture-new-branch'"), "Parent reactivation must retain the chosen source-control intent")
        XCUIDevice.shared.press(.home); app.activate(); waitConnected(app)
        app.buttons["new-session-card.Source Control"].tap()
        XCTAssertTrue(app.textFields["feature/my-work"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["feature/my-work"].value as? String, "fixture-new-branch")
        XCTAssertEqual(app.buttons.matching(identifier: "Start From").firstMatch.value as? String, "refs/heads/fixture-base")
        evidence(app, "348-new-session-draft-rejoin")
    }
    @MainActor func testAcceptedCreateRejoinsOriginalForegroundExactlyOnce() {
        continueAfterFailure = false
        let app = launch("accepted-background"); defer { app.terminate() }
        XCTAssertTrue(app.buttons["Create"].waitForExistence(timeout: 15)); app.buttons["Create"].tap()
        XCTAssertTrue(wait(app.staticTexts["fixture.create-counts"], "label CONTAINS 'typed:1'"))
        XCUIDevice.shared.press(.home); app.activate(); waitConnected(app)
        XCTAssertTrue(wait(app.staticTexts["fixture.create-result"], "label == 'callbacks:1 owned:true'"), "Accepted typed create result must rejoin original navigation admission")
        XCTAssertEqual(app.staticTexts["fixture.create-counts"].label, "creates:1 typed:1")
        XCTAssertFalse(app.buttons["new-session-card.Source Control"].exists)
        evidence(app, "348-new-session-create-background")
    }
    @MainActor func testAuthorityReplacementCannotReceiveAcceptedCreateRoute() {
        continueAfterFailure = false
        let app = launch("accepted-replace-profile"); defer { app.terminate() }
        XCTAssertTrue(app.buttons["Create"].waitForExistence(timeout: 15)); app.buttons["Create"].tap()
        XCTAssertTrue(wait(app.staticTexts["fixture.create-counts"], "label CONTAINS 'typed:1'"))
        XCUIDevice.shared.press(.home); app.activate(); waitConnected(app)
        XCTAssertEqual(app.staticTexts["fixture.create-result"].label, "callbacks:0 owned:false")
        XCTAssertEqual(app.staticTexts["fixture.create-counts"].label, "creates:1 typed:1")
        evidence(app, "348-new-session-create-replaced")
    }
    @MainActor func testWorkspaceReplacementInvalidatesSourceControlDraft() {
        continueAfterFailure = false
        let app = launch("draft"); defer { app.terminate() }
        chooseBranch(app); app.buttons["Done"].tap()
        changeWorkspace(app)
        app.buttons["new-session-card.Source Control"].tap()
        let mode = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'New Worktree · New Branch'")).firstMatch
        XCTAssertTrue(mode.waitForExistence(timeout: 10)); mode.tap()
        XCTAssertEqual(app.textFields["feature/my-work"].value as? String, "feature/my-work", "An earlier checkout's branch draft must not attach to the new workspace")
        evidence(app, "348-new-session-workspace-replaced")
    }
    @MainActor func testAcceptedCreateCannotNavigateOverNewerWorkspaceDraft() {
        continueAfterFailure = false
        let app = launch("accepted-newer-workspace"); defer { app.terminate() }
        XCTAssertTrue(app.buttons["Create"].waitForExistence(timeout: 15)); app.buttons["Create"].tap()
        XCTAssertTrue(wait(app.staticTexts["fixture.create-counts"], "label CONTAINS 'typed:1'"))
        changeWorkspace(app)
        XCUIDevice.shared.press(.home); app.activate(); waitConnected(app)
        XCTAssertTrue(app.staticTexts["new-session-created-elsewhere"].waitForExistence(timeout: 10))
        XCTAssertTrue(wait(app.buttons["new-session-card.Workspace"], "label CONTAINS '/fixture/replacement'"))
        XCTAssertEqual(app.staticTexts["fixture.create-result"].label, "callbacks:0 owned:false")
        XCTAssertEqual(app.staticTexts["fixture.create-counts"].label, "creates:1 typed:1")
        evidence(app, "348-new-session-newer-draft")
    }
    @MainActor func testProfileReplacementInvalidatesSourceControlDraft() {
        continueAfterFailure = false
        let app = launch("draft-replace-profile"); defer { app.terminate() }
        chooseBranch(app); app.buttons["Done"].tap()
        XCUIDevice.shared.press(.home); app.activate(); waitConnected(app)
        XCTAssertTrue(wait(app.buttons["new-session-card.Source Control"], "NOT label CONTAINS 'fixture-new-branch'"), "A replaced namespace must revoke the original source-control intent")
        XCTAssertTrue(app.buttons["Preparing"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Preparing"].isEnabled)
        evidence(app, "348-new-session-profile-draft-replaced")
    }
    @MainActor func testUserDismissalDoesNotReopenDraftOrCreate() {
        continueAfterFailure = false
        let app = launch("draft"); defer { app.terminate() }
        XCTAssertTrue(app.buttons["new-session-card.Workspace"].waitForExistence(timeout: 15))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.10))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        XCTAssertTrue(wait(app.buttons["new-session-card.Workspace"], "exists == false"))
        XCUIDevice.shared.press(.home); app.activate(); waitConnected(app)
        XCTAssertFalse(app.buttons["new-session-card.Workspace"].exists)
        XCTAssertEqual(app.staticTexts["fixture.create-counts"].label, "creates:0 typed:0")
        XCTAssertEqual(app.staticTexts["fixture.create-result"].label, "callbacks:0 owned:false")
        evidence(app, "348-new-session-dismissed")
    }
    @MainActor func testRetiredSubmissionCannotSendImplicitTrustToReplacementMac() {
        continueAfterFailure = false
        let app = launch("trust-before-profile"); defer { app.terminate() }
        XCTAssertTrue(app.buttons["Create"].waitForExistence(timeout: 15)); app.buttons["Create"].tap()
        XCTAssertTrue(wait(app.staticTexts["fixture.trust-counts"], "label CONTAINS 'held:1'"))
        app.buttons["new-session-card.Server"].tap()
        let server = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Replacement fixture'")).firstMatch
        XCTAssertTrue(server.waitForExistence(timeout: 10)); server.tap()
        XCTAssertTrue(wait(app.staticTexts["fixture.create-connection"], "label BEGINSWITH 'connected' AND label CONTAINS 'profile:new-session-replacement'"))
        XCTAssertTrue(wait(app.staticTexts["fixture.trust-counts"], "label CONTAINS 'released:1'"))
        XCTAssertTrue(wait(app.buttons["Create"], "exists == true AND enabled == false"))
        XCTAssertTrue(app.staticTexts["fixture.trust-counts"].label.hasPrefix("trusts:0 successor:0"), "Original cwd/trust fallback must never dispatch to a replacement Mac")
        XCTAssertEqual(app.staticTexts["fixture.create-counts"].label, "creates:0 typed:0")
        XCTAssertEqual(app.staticTexts["fixture.create-result"].label, "callbacks:0 owned:false")
        evidence(app, "348-new-session-pretrust-authority")
    }
    @MainActor func testBackgroundBeforeSubmissionSendsNeitherTrustNorCreate() {
        continueAfterFailure = false
        let app = launch("trust-before-background"); defer { app.terminate() }
        XCTAssertTrue(app.buttons["Create"].waitForExistence(timeout: 15)); app.buttons["Create"].tap()
        XCTAssertTrue(wait(app.staticTexts["fixture.trust-counts"], "label CONTAINS 'held:1'"))
        XCUIDevice.shared.press(.home); app.activate(); waitConnected(app)
        XCTAssertTrue(wait(app.staticTexts["fixture.trust-counts"], "label CONTAINS 'released:1'"))
        XCTAssertTrue(app.staticTexts["fixture.trust-counts"].label.hasPrefix("trusts:0 successor:0"))
        XCTAssertEqual(app.staticTexts["fixture.create-counts"].label, "creates:0 typed:0")
        XCTAssertEqual(app.staticTexts["fixture.create-result"].label, "callbacks:0 owned:false")
        evidence(app, "348-new-session-pretrust-background")
    }
    @MainActor func testOriginalUnresolvedTrustFallbackCreatesOnce() {
        continueAfterFailure = false
        let app = launch("trust-original"); defer { app.terminate() }
        XCTAssertTrue(app.buttons["Create"].waitForExistence(timeout: 15)); app.buttons["Create"].tap()
        XCTAssertTrue(wait(app.staticTexts["fixture.create-result"], "label == 'callbacks:1 owned:true'"))
        XCTAssertTrue(app.staticTexts["fixture.trust-counts"].label.hasPrefix("trusts:1 successor:0 fallback:true"))
        XCTAssertEqual(app.staticTexts["fixture.create-counts"].label, "creates:1 typed:0")
        evidence(app, "348-new-session-original-trust")
    }
    @MainActor func testAcceptedTrustDoesNotReplayOrAutomaticallyCreateAfterBackground() {
        continueAfterFailure = false
        let app = launch("trust-accepted-background"); defer { app.terminate() }
        XCTAssertTrue(app.buttons["Create"].waitForExistence(timeout: 15)); app.buttons["Create"].tap()
        XCTAssertTrue(wait(app.staticTexts["fixture.trust-counts"], "label CONTAINS 'acceptedHeld:1'"))
        XCUIDevice.shared.press(.home); app.activate(); waitConnected(app)
        XCTAssertTrue(wait(app.buttons["Create"], "exists == true AND enabled == true"))
        XCTAssertFalse(app.buttons["new-session-card.Project Trust"].exists, "Canonical accepted trust must reconcile without replay")
        XCTAssertEqual(app.staticTexts["fixture.create-counts"].label, "creates:0 typed:0")
        XCTAssertEqual(app.staticTexts["fixture.create-result"].label, "callbacks:0 owned:false")
        app.buttons["Create"].tap()
        XCTAssertTrue(wait(app.staticTexts["fixture.create-result"], "label == 'callbacks:1 owned:true'"))
        XCTAssertTrue(app.staticTexts["fixture.trust-counts"].label.hasPrefix("trusts:1 successor:0 fallback:true"))
        XCTAssertEqual(app.staticTexts["fixture.create-counts"].label, "creates:1 typed:0")
        evidence(app, "348-new-session-accepted-trust")
    }
    @MainActor private func changeWorkspace(_ app: XCUIApplication) {
        app.buttons["new-session-card.Workspace"].tap()
        XCTAssertTrue(app.buttons["replacement"].waitForExistence(timeout: 10)); app.buttons["replacement"].tap()
        XCTAssertTrue(wait(app.navigationBars.staticTexts.matching(NSPredicate(format: "label CONTAINS '/fixture/replacement'")).firstMatch, "exists == true"))
        app.buttons["Use current folder"].tap()
    }
    @MainActor private func chooseBranch(_ app: XCUIApplication) {
        let source = app.buttons["new-session-card.Source Control"]
        XCTAssertTrue(source.waitForExistence(timeout: 15)); source.tap()
        let mode = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'New Worktree · New Branch'")).firstMatch
        XCTAssertTrue(mode.waitForExistence(timeout: 10)); mode.tap()
        let branch = app.textFields["feature/my-work"]
        XCTAssertTrue(branch.waitForExistence(timeout: 10)); branch.tap(); branch.typeText("fixture-new-branch")
        app.buttons["Done"].tap()
        XCTAssertTrue(wait(source, "label CONTAINS 'fixture-new-branch'"), "Closing the child must retain the branch before reopening its base picker")
        source.tap()
        app.buttons.matching(identifier: "Start From").element(boundBy: 1).tap()
        XCTAssertTrue(app.buttons["fixture-base"].waitForExistence(timeout: 10)); app.buttons["fixture-base"].tap()
    }
    @MainActor private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["-tron-new-session-fixture", "-new-session-scenario", scenario]; app.launch(); return app
    }
    @MainActor private func wait(_ e: XCUIElement, _ predicate: String) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: e)], timeout: 12) == .completed
    }
    @MainActor private func waitConnected(_ app: XCUIApplication) {
        XCTAssertTrue(wait(app.staticTexts["fixture.create-connection"], "label BEGINSWITH 'connected' AND NOT label CONTAINS 'socket:1'"))
    }
    @MainActor private func evidence(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
        let text = XCTAttachment(string: app.staticTexts["fixture.create-counts"].label + "\n" + app.staticTexts["fixture.create-result"].label + "\n" + app.staticTexts["fixture.trust-counts"].label); text.name = name + "-counts"; text.lifetime = .keepAlways; add(text)
    }
}
