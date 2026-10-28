import XCTest

/// The production Tron menu → Apps → runner path against the real Gateway. The
/// app is installed by the real `swift_app` tool in a real Pi session.
extension RealGatewayPairAndChatUITests {
    @MainActor
    func testTronMenuListsInstalledAppAndKeepsItsValuesAcrossReopen() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let app = launchApp(additionalArguments: ["-appearanceMode", "light"])
        defer { app.terminate() }
        try installProofApp(app, fixture)
        app.buttons["Back"].tap()
        openApps(app)
        let row = proofRow(app, "Persistence proof")
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the installed app is not listed: \(app.debugDescription)")
        keepScreenshot(app, name: "2076-real-gateway-apps-sheet-light")
        row.tap()
        XCTAssertTrue(app.staticTexts["Count 0"].waitForExistence(timeout: 20), app.debugDescription)
        app.buttons["Add entry"].tap()
        XCTAssertTrue(app.staticTexts["Count 1"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Transient 1"].exists)
        closeRunner(app)

        // Reopen from the catalog: stored values come back, @State starts over.
        let reopened = proofRow(app, "Persistence proof")
        XCTAssertTrue(reopened.waitForExistence(timeout: 30), app.debugDescription)
        reopened.tap()
        XCTAssertTrue(app.staticTexts["Count 1"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Saved 1"].exists)
        XCTAssertTrue(app.staticTexts["Transient 0"].exists)
        keepScreenshot(app, name: "2076-real-gateway-apps-runner-reopened")
    }

    /// A save the Gateway refuses (the app was updated underneath the open
    /// runner) is shown, kept as unsaved work, and given up only on request.
    @MainActor
    func testRefusedSaveAfterAnAppUpdateIsShownAndKeptUntilDiscarded() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let app = launchApp(additionalArguments: ["-appearanceMode", "light"])
        defer { app.terminate() }
        try installProofApp(app, fixture)
        let go = URL(fileURLWithPath: fixture.workspace).appendingPathComponent(".reinstall-go-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: go); try? FileManager.default.removeItem(atPath: go.path + ".done") }
        try sendPrompt(app, "INSTALLED-SWIFT-APP-REINSTALL \(go.path)")
        app.buttons["Back"].tap()
        openApps(app)
        proofRow(app, "Persistence proof").tap()
        XCTAssertTrue(app.staticTexts["Count 0"].waitForExistence(timeout: 20), app.debugDescription)

        // Another writer updates the installed app while this runner is open.
        try Data().write(to: go)
        let deadline = Date().addingTimeInterval(120)
        while !FileManager.default.fileExists(atPath: go.path + ".done"), Date() < deadline { Thread.sleep(forTimeInterval: 0.25) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: go.path + ".done"), "the second writer never reinstalled the app")
        app.buttons["Add entry"].tap()
        let refusal = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "not saved")).firstMatch
        XCTAssertTrue(refusal.waitForExistence(timeout: 30), "a refused save was not shown: \(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["Count 1"].exists, "the runner must not silently roll back accepted work")
        keepScreenshot(app, name: "2076-real-gateway-refused-save-light")
        closeRunner(app)

        let updated = proofRow(app, "Persistence proof 2")
        XCTAssertTrue(updated.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Unsaved"].exists, "the catalog must mark the app with unsaved work")
        updated.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "not saved")).firstMatch.waitForExistence(timeout: 20),
                      "reopening must retain the failure instead of dropping it")
        XCTAssertTrue(app.staticTexts["Count 1"].exists)
        closeRunner(app)

        manage(app, proofRow(app, "Persistence proof 2"))
        tapManage(app, "discard")
        confirm(app, "Discard Changes")
        closeManage(app)
        proofRow(app, "Persistence proof 2").tap()
        XCTAssertTrue(app.staticTexts["Count 0"].waitForExistence(timeout: 20), "the discarded work must reload the updated app: \(app.debugDescription)")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "not saved")).firstMatch.exists)
    }

    @MainActor
    func testManageRenamesClearsDataAndRemovesOnlyAfterConfirmation() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let app = launchApp(additionalArguments: ["-appearanceMode", "light"])
        defer { app.terminate() }
        try installProofApp(app, fixture)
        app.buttons["Back"].tap()
        openApps(app)
        proofRow(app, "Persistence proof").tap()
        XCTAssertTrue(app.staticTexts["Count 0"].waitForExistence(timeout: 20), app.debugDescription)
        app.buttons["Add entry"].tap()
        XCTAssertTrue(app.staticTexts["Count 1"].waitForExistence(timeout: 10))
        closeRunner(app)

        manage(app, proofRow(app, "Persistence proof"))
        keepScreenshot(app, name: "2076-real-gateway-manage-light")
        tapManage(app, "rename")
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15), app.debugDescription)
        field.tap()
        if let value = field.value as? String, !value.isEmpty { field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count)) }
        field.typeText("Renamed proof")
        app.buttons["Save"].tap()
        closeManage(app)
        XCTAssertTrue(proofRow(app, "Renamed proof").waitForExistence(timeout: 30), "the rename never reached the catalog: \(app.debugDescription)")

        manage(app, proofRow(app, "Renamed proof"))
        tapManage(app, "reset")
        confirm(app, "Cancel")
        closeManage(app)
        proofRow(app, "Renamed proof").tap()
        XCTAssertTrue(app.staticTexts["Count 1"].waitForExistence(timeout: 20), "cancelling must not clear data")
        closeRunner(app)

        manage(app, proofRow(app, "Renamed proof"))
        tapManage(app, "reset")
        confirm(app, "Clear Data")
        closeManage(app)
        proofRow(app, "Renamed proof").tap()
        XCTAssertTrue(app.staticTexts["Count 0"].waitForExistence(timeout: 20), "data was not cleared: \(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["Saved 0"].exists)
        closeRunner(app)

        manage(app, proofRow(app, "Renamed proof"))
        tapManage(app, "remove")
        confirm(app, "Cancel")
        closeManage(app)
        XCTAssertTrue(proofRow(app, "Renamed proof").exists, "cancelling must not remove the app")
        manage(app, proofRow(app, "Renamed proof"))
        tapManage(app, "remove")
        confirm(app, "Remove App")
        XCTAssertTrue(app.descendants(matching: .any)["installed-apps-empty"].waitForExistence(timeout: 30),
                      "the removed app is still listed: \(app.debugDescription)")
        keepScreenshot(app, name: "2076-real-gateway-apps-empty-light")
    }

    @MainActor func testCaptureAppsAndManageLight() throws { try captureAppsAndManage(scheme: "light") }
    @MainActor func testCaptureAppsAndManageDark() throws { try captureAppsAndManage(scheme: "dark") }

    /// Review captures of the real production screens, not the design fixture.
    @MainActor
    private func captureAppsAndManage(scheme: String) throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let app = launchApp(additionalArguments: ["-appearanceMode", scheme])
        defer { app.terminate() }
        try installProofApp(app, fixture)
        app.buttons["Back"].tap()
        openApps(app)
        let row = proofRow(app, "Persistence proof")
        XCTAssertTrue(row.waitForExistence(timeout: 30), app.debugDescription)
        keepScreenshot(app, name: "apps-\(scheme)-list")
        row.tap()
        XCTAssertTrue(app.staticTexts["Count 0"].waitForExistence(timeout: 20), app.debugDescription)
        app.buttons["Add entry"].tap()
        XCTAssertTrue(app.staticTexts["Count 1"].waitForExistence(timeout: 10))
        keepScreenshot(app, name: "apps-\(scheme)-runner")
        closeRunner(app)
        manage(app, proofRow(app, "Persistence proof"))
        XCTAssertTrue(app.buttons["installed-app-manage-remove"].waitForExistence(timeout: 20))
        keepScreenshot(app, name: "apps-\(scheme)-manage")
        tapManage(app, "remove")
        XCTAssertTrue(app.buttons["Remove App"].waitForExistence(timeout: 15))
        keepScreenshot(app, name: "apps-\(scheme)-remove-confirmation")
        confirm(app, "Remove App")
        XCTAssertTrue(app.descendants(matching: .any)["installed-apps-empty"].waitForExistence(timeout: 30), app.debugDescription)
        keepScreenshot(app, name: "apps-\(scheme)-empty")
    }

    // MARK: Helpers

    @MainActor
    private func installProofApp(_ app: XCUIApplication, _ fixture: RealGatewayUIFixture) throws {
        open(fixture.invitationLink())
        completeFirstRunSetup(app, inWorkspace: fixture.workspace)
        XCTAssertTrue(waitForHittable(app.buttons["dashboard.menu"], timeout: 90), app.debugDescription)
        createSession(app, inWorkspace: fixture.workspace)
        try sendPrompt(app, "INSTALLED-SWIFT-APP-PERSISTENCE")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Installed persistence proof app")).firstMatch
            .waitForExistence(timeout: 90), "the agent's swift_app install never completed: \(app.debugDescription)")
    }

    @MainActor
    private func sendPrompt(_ app: XCUIApplication, _ text: String) throws {
        let composer = app.textViews["Message input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 60), app.debugDescription)
        composer.tap()
        composer.typeText(text)
        let send = app.buttons["Send message"]
        XCTAssertTrue(send.waitForExistence(timeout: 60) && waitForEnabled(send, timeout: 60), app.debugDescription)
        send.tap()
    }

    @MainActor
    private func openApps(_ app: XCUIApplication) {
        let menu = app.buttons["dashboard.menu"]
        XCTAssertTrue(waitForHittable(menu, timeout: 60), app.debugDescription)
        // With Home offered, a tap opens Home and a hold opens the menu.
        if menu.label == "Home" { menu.press(forDuration: 0.6) } else { menu.tap() }
        let apps = app.buttons["Apps"]
        XCTAssertTrue(apps.waitForExistence(timeout: 30), "the Tron menu has no Apps entry: \(app.debugDescription)")
        apps.tap()
    }

    @MainActor
    private func proofRow(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'installed-app-row-' AND label CONTAINS %@", title)).firstMatch
    }

    @MainActor
    private func manage(_ app: XCUIApplication, _ row: XCUIElement) {
        XCTAssertTrue(row.waitForExistence(timeout: 30), app.debugDescription)
        row.press(forDuration: 1.0)
        let manage = app.buttons["Manage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 15), app.debugDescription)
        manage.tap()
    }

    @MainActor
    private func tapManage(_ app: XCUIApplication, _ id: String) {
        let button = app.buttons["installed-app-manage-\(id)"]
        XCTAssertTrue(button.waitForExistence(timeout: 20), app.debugDescription)
        button.tap()
    }

    @MainActor
    private func confirm(_ app: XCUIApplication, _ title: String) {
        let button = app.buttons[title]
        XCTAssertTrue(button.waitForExistence(timeout: 15), app.debugDescription)
        button.tap()
    }

    @MainActor
    private func closeRunner(_ app: XCUIApplication) { closeTopSheet(app) }

    @MainActor
    private func closeManage(_ app: XCUIApplication) { closeTopSheet(app) }

    /// Each sheet owns one Done; the topmost is the last hittable.
    @MainActor
    private func closeTopSheet(_ app: XCUIApplication) {
        let done = app.buttons.matching(identifier: "Done")
        XCTAssertTrue(done.firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        (done.allElementsBoundByIndex.last(where: { $0.isHittable }) ?? done.firstMatch).tap()
    }
}
