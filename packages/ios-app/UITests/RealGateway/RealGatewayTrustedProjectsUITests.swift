import Foundation
import XCTest

/// #1517/#2010: Global Settings › Agent Behavior against the real Gateway.
/// The embedded Trusted Projects group owns the default trust policy and
/// every saved project decision (the Connection group repeats neither),
/// and Add Project records the chosen folder through `settings.change` as Not
/// trusted: it joins the list untoggled and the Gateway's trust store holds
/// `false` for it. A per-model key's all-models instance is titled "All
/// models", never by its fixed `role=chat` qualifier. #1569: a folder nested
/// under a listed project is added as its own entry (the store resolves the
/// nearest saved decision), and its row then trusts it alone.
extension RealGatewayPairAndChatUITests {
    @MainActor
    func testTrustedProjectsListsAndAddsProjectsUntrusted() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let root = URL(fileURLWithPath: fixture.workspace).deletingLastPathComponent()
        let added = root.appendingPathComponent("added-project")
        let seeded = root.appendingPathComponent("trusted-project")
        let parent = root.appendingPathComponent("blocked-parent")
        let nested = parent.appendingPathComponent("nested-project")
        for folder in [added, seeded, nested] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        // A saved decision the Gateway reads from its own trust store.
        let trustStore = URL(fileURLWithPath: try XCTUnwrap(fixture.agentDirectory)).appendingPathComponent("trust.json")
        // The fixture workspace is already canonical (realpath), as the Gateway records
        // projects; Foundation's symlink resolution would drop /private and miss it.
        let parentPath = parent.path
        try JSONSerialization.data(withJSONObject: [seeded.resolvingSymlinksInPath().path: true, parentPath: false])
            .write(to: trustStore)
        func stored(_ name: String) -> Bool? {
            let document = (try? JSONSerialization.jsonObject(with: Data(contentsOf: trustStore))) as? [String: Any]
            return document?.first { ($0.key as NSString).lastPathComponent == name }?.value as? Bool
        }

        let app = launchApp(additionalArguments: ["-appearanceMode", "light"])
        defer { app.terminate() }
        open(fixture.invitationLink())
        completeFirstRunSetup(app, inWorkspace: fixture.workspace)
        XCTAssertTrue(waitForHittable(app.buttons["dashboard.menu"], timeout: 90), app.debugDescription)
        createSession(app, inWorkspace: fixture.workspace)
        let gear = app.navigationBars.buttons["Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 30), app.debugDescription)
        gear.tap()
        XCTAssertTrue(app.buttons["settings-done"].waitForExistence(timeout: 30), app.debugDescription)

        openAgentBehavior(app)
        let allModels = app.staticTexts["All models"].firstMatch
        revealBelowNavigationBar(app, allModels)
        XCTAssertTrue(allModels.exists, "Thinking's all-models instance must be titled All models")
        XCTAssertFalse(app.staticTexts["chat"].exists, "a fixed qualifier must not title a row")

        let run = app.descendants(matching: .any)["settings-section-run-detail"]
        revealBelowNavigationBar(app, run)
        XCTAssertTrue(run.waitForExistence(timeout: 30))
        XCTAssertFalse(run.staticTexts["Trust for this project"].exists, "Connection must not duplicate per-project trust")
        XCTAssertFalse(run.staticTexts["Default trust policy"].exists, "Connection must not duplicate the default trust policy")
        let projects = app.buttons["Trusted Projects"]
        revealBelowNavigationBar(app, projects)
        projects.tap()
        _ = app.descendants(matching: .any)["settings-row-permissions.defaultProjectTrust"].waitForExistence(timeout: 30)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "settings-row-permissions.defaultProjectTrust").count, 1,
                       "The consolidated sheet owns one default trust policy")
        keepScreenshot(app, name: "after-agent-behavior-trusted-projects")
        XCTAssertTrue(app.descendants(matching: .any)["settings-row-permissions.defaultProjectTrust"].waitForExistence(timeout: 30),
                      app.debugDescription)
        let seededRow = app.buttons.matching(NSPredicate(format: "label == %@", "trusted-project")).firstMatch
        XCTAssertTrue(seededRow.waitForExistence(timeout: 30), "the saved decision is not listed: \(app.debugDescription)")
        XCTAssertEqual(seededRow.value as? String, "1")

        let add = app.buttons["Add Project"]
        revealBelowNavigationBar(app, add)
        add.tap()
        app.buttons["Choose Existing Folder"].tap()
        let folder = app.buttons.matching(NSPredicate(format: "label == %@", "added-project")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 60), app.debugDescription)
        folder.tap()
        let useCurrent = app.buttons["Use current folder"]
        XCTAssertTrue(waitForEnabled(useCurrent, timeout: 60), app.debugDescription)
        useCurrent.tap()

        let row = app.buttons.matching(NSPredicate(format: "label == %@", "added-project")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the added project is not listed: \(app.debugDescription)")
        XCTAssertEqual(row.value as? String, "0", "an added project must start untrusted")
        XCTAssertTrue(waitUntil(timeout: 15) { stored("added-project") == false },
                      "the Gateway trust store must record the added project as not trusted")
        XCTAssertEqual(seededRow.value as? String, "1", "adding must not change another project's decision")
        keepScreenshot(app, name: "after-trusted-projects-default-policy")

        // A folder inside a listed (blocked) project is its own project.
        revealBelowNavigationBar(app, add)
        add.tap()
        app.buttons["Choose Existing Folder"].tap()
        let parentFolder = app.buttons.matching(NSPredicate(format: "label == %@", "blocked-parent")).firstMatch
        XCTAssertTrue(parentFolder.waitForExistence(timeout: 60), app.debugDescription)
        parentFolder.tap()
        let nestedFolder = app.buttons.matching(NSPredicate(format: "label == %@", "nested-project")).firstMatch
        XCTAssertTrue(nestedFolder.waitForExistence(timeout: 60), app.debugDescription)
        nestedFolder.tap()
        XCTAssertTrue(waitForEnabled(useCurrent, timeout: 60), app.debugDescription)
        useCurrent.tap()
        let nestedRow = app.buttons.matching(NSPredicate(format: "label == %@", "nested-project")).firstMatch
        XCTAssertTrue(nestedRow.waitForExistence(timeout: 30), "a folder inside a listed project was not added: \(app.debugDescription)")
        XCTAssertTrue(waitUntil(timeout: 15) { stored("nested-project") == false },
                      "the Gateway trust store must record the nested project as not trusted")
        XCTAssertEqual(stored("blocked-parent"), false, "adding a nested project must not change its parent's decision")
        keepScreenshot(app, name: "after-trusted-projects-nested-added")
    }

    /// #1570: New Session › Project Settings shows a blocked project's trust and
    /// its row opens the project's trust editor, whose Trust Project records
    /// `true` for that project in the Gateway's trust store.
    @MainActor
    func testProjectSettingsTrustRowTrustsABlockedProject() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let workspace = fixture.workspace
        let trustStore = URL(fileURLWithPath: try XCTUnwrap(fixture.agentDirectory)).appendingPathComponent("trust.json")
        try JSONSerialization.data(withJSONObject: [workspace: false]).write(to: trustStore)
        func stored() -> Bool? {
            ((try? JSONSerialization.jsonObject(with: Data(contentsOf: trustStore))) as? [String: Any])?[workspace] as? Bool
        }

        let app = launchApp(additionalArguments: ["-appearanceMode", "light"])
        defer { app.terminate() }
        open(fixture.invitationLink())
        completeFirstRunSetup(app, inWorkspace: fixture.workspace)
        let menu = app.buttons["dashboard.menu"]
        XCTAssertTrue(waitForEnabled(menu, timeout: 90), app.debugDescription)
        menu.tap()
        let newSession = app.buttons["New Session"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 30), app.debugDescription)
        newSession.tap()
        let projectSettings = app.buttons["project-settings-link"]
        XCTAssertTrue(projectSettings.waitForExistence(timeout: 60), app.debugDescription)
        projectSettings.tap()

        let trustRow = app.buttons["project-settings-trust"]
        XCTAssertTrue(trustRow.waitForExistence(timeout: 30), "Project Settings offers no way to change trust: \(app.debugDescription)")
        XCTAssertTrue(waitUntil(timeout: 30) { trustRow.value as? String == "Resources blocked" }, "\(String(describing: trustRow.value))")
        keepScreenshot(app, name: "project-settings-blocked")
        trustRow.tap()
        let trust = app.buttons["Trust Project"]
        XCTAssertTrue(trust.waitForExistence(timeout: 30), app.debugDescription)
        trust.tap()
        XCTAssertTrue(waitUntil(timeout: 15) { stored() == true }, "the Gateway trust store must record the project as trusted")
        dismissTopSheet(app)
        XCTAssertTrue(waitUntil(timeout: 30) { trustRow.value as? String == "Trusted" },
                      "Project Settings must show the new decision: \(String(describing: trustRow.value))")
        keepScreenshot(app, name: "project-settings-trusted")
    }
}
