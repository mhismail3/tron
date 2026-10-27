import Foundation
import XCTest

/// #1517/#2010: Global Settings › Agent Behavior against the real Gateway.
/// The Trusted Projects sheet owns the default policy and saved decisions;
/// the Connection group repeats neither. Project buttons open detail sheets.
/// Choosing an existing folder only inspects it (including nested folders),
/// preserving every trust record. A new project receives trust only after
/// the separate canonical approval tap. A per-model key's all-models instance
/// is titled "All models", never by its fixed `role=chat` qualifier.
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
        seededRow.tap()
        XCTAssertTrue(app.descendants(matching: .any)["project-lifecycle-details"].waitForExistence(timeout: 30),
                      "A project button must open its project sheet")
        XCTAssertEqual(stored("trusted-project"), true)
        func closeSheet() throws {
            try XCTUnwrap(app.buttons.matching(identifier: "Done").allElementsBoundByIndex.last(where: { $0.isHittable }),
                          "The top project sheet must offer Done").tap()
        }
        try closeSheet()
        let trustBeforeSelection = try Data(contentsOf: trustStore)

        let add = app.buttons["Add Project"]
        revealBelowNavigationBar(app, add)
        add.tap()
        app.buttons["project-lifecycle-existing"].tap()
        let folder = app.buttons.matching(NSPredicate(format: "label == %@", "added-project")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 60), app.debugDescription)
        folder.tap()
        let useCurrent = app.buttons["Use current folder"]
        XCTAssertTrue(waitForEnabled(useCurrent, timeout: 60), app.debugDescription)
        useCurrent.tap()

        let row = app.navigationBars.staticTexts["added-project"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the added project is not listed: \(app.debugDescription)")
        XCTAssertTrue(app.descendants(matching: .any)["project-lifecycle-details"].exists,
                      "Choosing a folder opens its inspection sheet, not a trust switch")
        XCTAssertTrue(waitUntil(timeout: 15) { (try? Data(contentsOf: trustStore)) == trustBeforeSelection },
                      "Inspecting a folder must leave the entire Gateway trust store unchanged")
        XCTAssertNil(stored("added-project"), "Inspection must not persist even an explicit false decision")
        XCTAssertEqual(stored("trusted-project"), true, "adding must not change another project's decision")
        keepScreenshot(app, name: "after-trusted-projects-default-policy")

        try closeSheet() // Selected folder inspection.
        try closeSheet() // Add Project, back to the project list.
        // A folder inside a listed (blocked) project can also be inspected.
        revealBelowNavigationBar(app, add)
        add.tap()
        app.buttons["project-lifecycle-existing"].tap()
        let parentFolder = app.buttons.matching(NSPredicate(format: "label == %@", "blocked-parent")).firstMatch
        XCTAssertTrue(parentFolder.waitForExistence(timeout: 60), app.debugDescription)
        parentFolder.tap()
        let nestedFolder = app.buttons.matching(NSPredicate(format: "label == %@", "nested-project")).firstMatch
        XCTAssertTrue(nestedFolder.waitForExistence(timeout: 60), app.debugDescription)
        nestedFolder.tap()
        XCTAssertTrue(waitForEnabled(useCurrent, timeout: 60), app.debugDescription)
        useCurrent.tap()
        let nestedRow = app.navigationBars.staticTexts["nested-project"]
        XCTAssertTrue(nestedRow.waitForExistence(timeout: 30), "a folder inside a listed project was not added: \(app.debugDescription)")
        XCTAssertTrue(waitUntil(timeout: 15) { (try? Data(contentsOf: trustStore)) == trustBeforeSelection },
                      "Nested inspection must preserve the parent's and every other saved decision")
        XCTAssertNil(stored("nested-project"), "Nested inspection must not persist a decision")
        XCTAssertEqual(stored("blocked-parent"), false, "adding a nested project must not change its parent's decision")
        keepScreenshot(app, name: "after-trusted-projects-nested-added")
        try closeSheet()
        try closeSheet()

        // Exercise the actual native request/decision route, not a settings
        // write: create records false, and only the separate digest tap trusts.
        add.tap()
        app.buttons["Create Project"].tap()
        let field = app.textFields["project-lifecycle-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), app.debugDescription)
        field.tap()
        field.typeText("selection-approved\n")
        let create = app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", "Create Project", "Create Project, ")).allElementsBoundByIndex.last(where: { $0.isHittable })
        try XCTUnwrap(create).tap()
        let approve = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'settings-approval-approve-'")).firstMatch
        XCTAssertTrue(approve.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertEqual(stored("selection-approved"), false, "projects.request alone must not grant trust")
        approve.tap()
        XCTAssertTrue(waitUntil(timeout: 15) { stored("selection-approved") == true },
                      "Trust must change only after the separate settings.decide approval tap")
        XCTAssertEqual(stored("trusted-project"), true)
        XCTAssertEqual(stored("blocked-parent"), false)
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
