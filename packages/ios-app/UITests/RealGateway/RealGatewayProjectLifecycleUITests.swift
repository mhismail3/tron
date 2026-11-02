import Foundation
import XCTest

/// Production pages → real socket → lifecycle owner/Git/trust store. No scripted
/// responses or live GitHub publication; every decision is a separate toolbar tap.
extension RealGatewayPairAndChatUITests {
    @MainActor
    func testProjectLifecycleApproveMovesAndArchives() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let app = try lifecycleSettings(fixture)
        defer { app.terminate() }
        let source = URL(fileURLWithPath: fixture.workspace).appendingPathComponent("lifecycle-approved")
        let destination = source.deletingLastPathComponent().appendingPathComponent("lifecycle-renamed")
        try lifecycleCreate(app, name: source.lastPathComponent)
        // The review alone has no effects: only the exact tap creates and trusts.
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "The review alone must not create the project")
        XCTAssertNil(try lifecycleTrust(fixture, path: source.path), "The review alone must not record trust")
        lifecycleDecide(app, approve: true)
        XCTAssertTrue(waitUntil(timeout: 15) { (try? self.lifecycleTrust(fixture, path: source.path)) == true })
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent(".git/HEAD"), encoding: .utf8), "ref: refs/heads/main\n")
        lifecycleClose(app)
        lifecycleBackToList(app)
        lifecycleTap(app, source.lastPathComponent)
        lifecycleTap(app, "Rename Project")
        lifecycleName(app, destination.lastPathComponent)
        lifecycleTap(app, "Request Rename")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "A request alone must not move files")
        lifecycleDecide(app, approve: true)
        XCTAssertTrue(waitUntil(timeout: 15) { FileManager.default.fileExists(atPath: destination.path) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try lifecycleTrust(fixture, path: destination.path), true)
        lifecycleClose(app)
        lifecycleBackToList(app)
        lifecycleTap(app, destination.lastPathComponent)
        lifecycleTap(app, "project-lifecycle-untrust")
        lifecycleDecide(app, approve: true)
        XCTAssertTrue(waitUntil(timeout: 15) { (try? self.lifecycleTrust(fixture, path: destination.path)) == false })
        // Approve retires the review and returns to the requesting details page.
        lifecycleTap(app, "project-lifecycle-archive")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        lifecycleDecide(app, approve: true)
        XCTAssertTrue(waitUntil(timeout: 15) { !FileManager.default.fileExists(atPath: destination.path) })
        let archives = try FileManager.default.contentsOfDirectory(at: destination.deletingLastPathComponent().appendingPathComponent(".archive"), includingPropertiesForKeys: nil)
        let retained = try XCTUnwrap(archives.first { $0.lastPathComponent.hasPrefix("lifecycle-renamed-") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.appendingPathComponent(".git/HEAD").path), "Archive must retain the repository")
        XCTAssertEqual(try lifecycleTrust(fixture, path: retained.path), false)
        keepScreenshot(app, name: "2023-real-gateway-approved-archive")
    }

    @MainActor
    func testProjectLifecycleListOmitsArchivedAndDepartedProjects() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let app = try lifecycleSettings(fixture)
        defer { app.terminate() }
        let source = URL(fileURLWithPath: fixture.workspace).appendingPathComponent("departed-project")
        let destination = source.deletingLastPathComponent().appendingPathComponent("archived-project")
        func row(_ name: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", name, name + ", ")).firstMatch
        }
        // A cancelled Create has no effects (Denial journey); approve a real source.
        try lifecycleCreate(app, name: source.lastPathComponent)
        lifecycleDecide(app, approve: true)
        lifecycleClose(app)
        lifecycleBackToList(app)
        XCTAssertTrue(row(source.lastPathComponent).waitForExistence(timeout: 15), "The list selector must find the live source before testing its removal: \(app.debugDescription)")
        lifecycleTap(app, source.lastPathComponent)
        lifecycleTap(app, "Rename Project")
        lifecycleName(app, destination.lastPathComponent)
        lifecycleTap(app, "Request Rename")
        lifecycleDecide(app, approve: true)
        XCTAssertTrue(waitUntil(timeout: 15) { FileManager.default.fileExists(atPath: destination.path) })
        lifecycleClose(app)
        lifecycleBackToList(app)
        lifecycleTap(app, destination.lastPathComponent)
        lifecycleTap(app, "project-lifecycle-archive")
        lifecycleDecide(app, approve: true)
        XCTAssertTrue(waitUntil(timeout: 15) { !FileManager.default.fileExists(atPath: destination.path) })
        let archives = try FileManager.default.contentsOfDirectory(at: destination.deletingLastPathComponent().appendingPathComponent(".archive"), includingPropertiesForKeys: nil)
        let retained = try XCTUnwrap(archives.first { $0.lastPathComponent.hasPrefix("archived-project-") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.appendingPathComponent(".git/HEAD").path))
        lifecycleClose(app)
        lifecycleBackToList(app)
        // Observe the actual refreshed list after both filesystem effects. Keep
        // all three failures so one run distinguishes tombstones from archives.
        continueAfterFailure = true
        for name in [source.lastPathComponent, destination.lastPathComponent, retained.lastPathComponent] {
            XCTAssertTrue(waitUntil(timeout: 15) { !row(name).exists },
                          "Departed and archived projects must not return as saved-decision ghost rows: \(name)")
        }
        keepScreenshot(app, name: "2023-real-gateway-list-after-archive")
    }

    @MainActor
    func testProjectLifecycleDenialRetainsUntrustedRepository() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let app = try lifecycleSettings(fixture)
        defer { app.terminate() }
        let source = URL(fileURLWithPath: fixture.workspace).appendingPathComponent("lifecycle-denied")
        try lifecycleCreate(app, name: source.lastPathComponent)
        lifecycleDecide(app, approve: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "A cancelled Create must leave no repository")
        XCTAssertNil(try lifecycleTrust(fixture, path: source.path), "A cancelled Create must record no trust")
        lifecycleClose(app)
        lifecycleBackToList(app)
        // A real repository, explicitly untrusted through its own exact tap,
        // must survive a denied rename with no move and no new authority.
        try lifecycleCreate(app, name: source.lastPathComponent)
        lifecycleDecide(app, approve: true)
        XCTAssertTrue(waitUntil(timeout: 15) { (try? self.lifecycleTrust(fixture, path: source.path)) == true })
        lifecycleClose(app)
        lifecycleBackToList(app)
        lifecycleTap(app, source.lastPathComponent)
        lifecycleTap(app, "project-lifecycle-untrust")
        lifecycleDecide(app, approve: true)
        XCTAssertTrue(waitUntil(timeout: 15) { (try? self.lifecycleTrust(fixture, path: source.path)) == false })
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent(".git/HEAD").path))
        lifecycleTap(app, "Rename Project")
        lifecycleName(app, "must-not-exist")
        lifecycleTap(app, "Request Rename")
        lifecycleDecide(app, approve: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.deletingLastPathComponent().appendingPathComponent("must-not-exist").path))
        XCTAssertEqual(try lifecycleTrust(fixture, path: source.path), false)
        keepScreenshot(app, name: "2023-real-gateway-denied-rename")
    }

    /// #2206: a confirmed action the Gateway refuses right away (the path appeared
    /// after review) is reported on the requesting page even though its review
    /// card is still closing; nothing is created or trusted.
    @MainActor
    func testProjectLifecycleRefusedApprovalShowsItsReason() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let app = try lifecycleSettings(fixture)
        defer { app.terminate() }
        let source = URL(fileURLWithPath: fixture.workspace).appendingPathComponent("lifecycle-raced")
        try lifecycleCreate(app, name: source.lastPathComponent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "The review alone must not create the project")
        // Another writer takes the reviewed path before the exact tap.
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        app.buttons["change-review-approve"].tap()
        let refusal = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "already exists")).firstMatch
        XCTAssertTrue(refusal.waitForExistence(timeout: 20), "The refusal must reach the requesting page: \(app.debugDescription)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent(".git").path), "A refused create initializes nothing")
        XCTAssertNil(try lifecycleTrust(fixture, path: source.path), "A refused create records no trust")
        keepScreenshot(app, name: "2206-refused-approval-reason")
    }

    @MainActor
    func testProjectLifecycleBusyArchiveUsesCanonicalReason() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let app = try lifecycleSettings(fixture)
        defer { app.terminate() }
        lifecycleTap(app, "busy-project")
        let archive = app.buttons["project-lifecycle-archive"]
        XCTAssertTrue(archive.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(archive.isEnabled)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "linked worktrees")).firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: fixture.workspace).appendingPathComponent("busy-project/.git/HEAD").path))
        XCTAssertNotEqual(try lifecycleTrust(fixture, path: URL(fileURLWithPath: fixture.workspace).appendingPathComponent("busy-project").path), true)
        keepScreenshot(app, name: "2023-real-gateway-linked-worktree-refusal")
    }

    @MainActor
    private func lifecycleSettings(_ fixture: RealGatewayUIFixture) throws -> XCUIApplication {
        let app = launchApp(additionalArguments: ["-appearanceMode", "light"])
        open(fixture.invitationLink())
        completeFirstRunSetup(app, inWorkspace: fixture.workspace)
        XCTAssertTrue(waitForHittable(app.buttons["dashboard.menu"], timeout: 90), app.debugDescription)
        createSession(app, inWorkspace: fixture.workspace)
        lifecycleTap(app, "Settings")
        openAgentBehavior(app)
        lifecycleTap(app, "Trusted Projects")
        return app
    }

    @MainActor
    private func lifecycleCreate(_ app: XCUIApplication, name: String) throws {
        lifecycleTap(app, "Add Project")
        lifecycleTap(app, "Create Project")
        lifecycleName(app, name)
        lifecycleTap(app, "Create Project")
        XCTAssertTrue(app.buttons["change-review-approve"].waitForExistence(timeout: 15), app.debugDescription)
    }

    @MainActor
    private func lifecycleName(_ app: XCUIApplication, _ name: String) {
        let field = app.textFields["project-lifecycle-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), app.debugDescription)
        field.tap()
        if let value = field.value as? String, !value.isEmpty, value != "Project name" {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        field.typeText(name + "\n")
    }

    @MainActor
    private func lifecycleTap(_ app: XCUIApplication, _ identifier: String) {
        let matches = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@ OR label BEGINSWITH %@", identifier, identifier, identifier + ", "))
        let button = matches.allElementsBoundByIndex.last(where: { $0.isHittable }) ?? matches.firstMatch
        if app.navigationBars.buttons.matching(identifier: identifier).count == 0 {
            revealBelowNavigationBar(app, button)
        }
        XCTAssertTrue(waitForHittable(button, timeout: 15), app.debugDescription)
        button.tap()
    }

    @MainActor
    private func lifecycleDecide(_ app: XCUIApplication, approve: Bool) {
        let button = app.buttons[approve ? "change-review-approve" : "change-review-cancel"]
        XCTAssertTrue(button.waitForExistence(timeout: 15), app.debugDescription)
        button.tap()
        XCTAssertTrue(waitUntil(timeout: 20) { app.buttons.matching(identifier: "Done").allElementsBoundByIndex.contains(where: { $0.isHittable }) }, app.debugDescription)
    }

    @MainActor
    private func lifecycleClose(_ app: XCUIApplication) {
        let done = app.buttons.matching(identifier: "Done").allElementsBoundByIndex.last(where: { $0.isHittable })
        XCTAssertNotNil(done, app.debugDescription)
        done?.tap()
    }

    @MainActor
    private func lifecycleBackToList(_ app: XCUIApplication) {
        for _ in 0..<4 where !app.buttons.matching(identifier: "Add Project").allElementsBoundByIndex.contains(where: { $0.isHittable }) { lifecycleClose(app) }
        XCTAssertTrue(app.buttons.matching(identifier: "Add Project").allElementsBoundByIndex.contains(where: { $0.isHittable }), app.debugDescription)
    }

    /// The canonical Project trust store; an absent file holds no decision.
    private func lifecycleTrust(_ fixture: RealGatewayUIFixture, path: String) throws -> Bool? {
        let store = URL(fileURLWithPath: try XCTUnwrap(fixture.agentDirectory)).appendingPathComponent("trust.json")
        guard FileManager.default.fileExists(atPath: store.path) else { return nil }
        return (try JSONSerialization.jsonObject(with: Data(contentsOf: store)) as? [String: Bool])?[path]
    }
}
