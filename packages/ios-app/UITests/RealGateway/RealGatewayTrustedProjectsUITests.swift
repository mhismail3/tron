import Foundation
import XCTest

/// #1517: Settings › Trusted Projects against the real Gateway. The Agent
/// group's Trusted Projects row opens a sheet that owns the default trust
/// policy and every saved project decision (More Settings repeats neither),
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
        let parentPath = parent.resolvingSymlinksInPath().path
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

        openSettingsSection(app, "model")
        let allModels = app.staticTexts["All models"].firstMatch
        revealBelowNavigationBar(app, allModels)
        XCTAssertTrue(allModels.exists, "Thinking's all-models instance must be titled All models")
        XCTAssertFalse(app.staticTexts["chat"].exists, "a fixed qualifier must not title a row")
        dismissTopSheet(app)

        openSettingsSection(app, "advanced")
        XCTAssertTrue(app.descendants(matching: .any)["settings-section-run-detail"].waitForExistence(timeout: 30))
        for _ in 0..<4 { app.swipeUp() }
        XCTAssertFalse(app.staticTexts["Trust for this project"].exists, "More Settings still lists per-project trust")
        XCTAssertFalse(app.staticTexts["Default trust policy"].exists, "More Settings still lists the default trust policy")
        dismissTopSheet(app)

        // The row sits in the Agent group, directly above More Settings (#1521).
        let trusted = app.buttons["settings-link-Trusted Projects"]
        let more = app.buttons["settings-section-advanced-open"]
        revealBelowNavigationBar(app, more)
        XCTAssertEqual(trusted.frame.minX, more.frame.minX, accuracy: 1)
        XCTAssertTrue(more.frame.minY >= trusted.frame.maxY - 1 && more.frame.minY < trusted.frame.maxY + 12,
                      "Trusted Projects must directly precede More Settings in the Agent card: \(trusted.frame) \(more.frame)")
        keepScreenshot(app, name: "after-settings-agent-trusted-projects")
        trusted.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings-row-permissions.defaultProjectTrust"].waitForExistence(timeout: 30),
                      app.debugDescription)
        let seededRow = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "trusted-project")).firstMatch
        XCTAssertTrue(seededRow.waitForExistence(timeout: 30), "the saved decision is not listed: \(app.debugDescription)")
        XCTAssertEqual(seededRow.value as? String, "1")

        let add = app.buttons["trusted-projects-add"]
        revealBelowNavigationBar(app, add)
        add.tap()
        let folder = app.buttons.matching(NSPredicate(format: "label == %@", "added-project")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 60), app.debugDescription)
        folder.tap()
        let useCurrent = app.buttons["Use current folder"]
        XCTAssertTrue(waitForEnabled(useCurrent, timeout: 60), app.debugDescription)
        useCurrent.tap()

        let row = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "added-project")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the added project is not listed: \(app.debugDescription)")
        XCTAssertEqual(row.value as? String, "0", "an added project must start untrusted")
        XCTAssertTrue(waitUntil(timeout: 15) { stored("added-project") == false },
                      "the Gateway trust store must record the added project as not trusted")
        XCTAssertEqual(seededRow.value as? String, "1", "adding must not change another project's decision")
        keepScreenshot(app, name: "after-trusted-projects-default-policy")

        // A folder inside a listed (blocked) project is its own project.
        revealBelowNavigationBar(app, add)
        add.tap()
        let parentFolder = app.buttons.matching(NSPredicate(format: "label == %@", "blocked-parent")).firstMatch
        XCTAssertTrue(parentFolder.waitForExistence(timeout: 60), app.debugDescription)
        parentFolder.tap()
        let nestedFolder = app.buttons.matching(NSPredicate(format: "label == %@", "nested-project")).firstMatch
        XCTAssertTrue(nestedFolder.waitForExistence(timeout: 60), app.debugDescription)
        nestedFolder.tap()
        XCTAssertTrue(waitForEnabled(useCurrent, timeout: 60), app.debugDescription)
        useCurrent.tap()
        let nestedRow = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "nested-project")).firstMatch
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
        let workspace = URL(fileURLWithPath: fixture.workspace).resolvingSymlinksInPath().path
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
