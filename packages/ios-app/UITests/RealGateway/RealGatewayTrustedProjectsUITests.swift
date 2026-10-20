import Foundation
import XCTest

/// #1517: Settings › Trusted Projects against the real Gateway. The per-project
/// trust rows live on their own sheet, not in More Settings, and Add Project
/// records the chosen folder through `settings.change` as Not trusted: it joins
/// the list untoggled and the Gateway's trust store holds `false` for it.
extension RealGatewayPairAndChatUITests {
    @MainActor
    func testTrustedProjectsListsAndAddsProjectsUntrusted() throws {
        continueAfterFailure = true
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let added = URL(fileURLWithPath: fixture.workspace).deletingLastPathComponent().appendingPathComponent("added-project")
        try FileManager.default.createDirectory(at: added, withIntermediateDirectories: true)
        // A saved decision the Gateway reads from its trust store: the sheet lists it.
        let seeded = added.deletingLastPathComponent().appendingPathComponent("trusted-project")
        try FileManager.default.createDirectory(at: seeded, withIntermediateDirectories: true)
        let trustStore = URL(fileURLWithPath: try XCTUnwrap(fixture.agentDirectory)).appendingPathComponent("trust.json")
        try JSONSerialization.data(withJSONObject: [seeded.resolvingSymlinksInPath().path: true]).write(to: trustStore)
        defer { XCUIDevice.shared.appearance = .light }
        XCUIDevice.shared.appearance = .light
        let app = launchApp(additionalArguments: ["-appearanceMode", "auto"])
        defer { app.terminate() }
        open(fixture.invitationLink())
        completeFirstRunSetup(app, inWorkspace: fixture.workspace)
        XCTAssertTrue(waitForHittable(app.buttons["dashboard.menu"], timeout: 90), app.debugDescription)
        createSession(app, inWorkspace: fixture.workspace)

        func openSettings() {
            let gear = app.navigationBars.buttons["Settings"]
            XCTAssertTrue(gear.waitForExistence(timeout: 30), app.debugDescription)
            gear.tap()
            XCTAssertTrue(app.buttons["settings-done"].waitForExistence(timeout: 30), app.debugDescription)
        }
        func reveal(_ element: XCUIElement) { revealBelowNavigationBar(app, element) }
        func tour(_ scheme: String) {
            openSettings()
            keepScreenshot(app, name: "\(scheme)-settings-top")
            let trusted = app.buttons["settings-link-Trusted Projects"]
            reveal(trusted)
            keepScreenshot(app, name: "\(scheme)-settings-tools")
            reveal(app.buttons["settings-section-model-open"])
            keepScreenshot(app, name: "\(scheme)-settings-agent")
            for _ in 0..<6 { app.swipeDown() }

            openSettingsSection(app, "model")
            keepScreenshot(app, name: "\(scheme)-models-top")
            reveal(app.staticTexts["All models"].firstMatch)
            keepScreenshot(app, name: "\(scheme)-models-thinking")
            dismissTopSheet(app)

            openSettingsSection(app, "context")
            reveal(app.staticTexts["Response reserve"].firstMatch)
            keepScreenshot(app, name: "\(scheme)-compaction-reserve")
            reveal(app.staticTexts["Kept after compaction"].firstMatch)
            keepScreenshot(app, name: "\(scheme)-compaction-kept")
            dismissTopSheet(app)

            openSettingsSection(app, "advanced")
            keepScreenshot(app, name: "\(scheme)-more-settings-top")
            for _ in 0..<3 { app.swipeUp() }
            keepScreenshot(app, name: "\(scheme)-more-settings-scrolled")
            XCTAssertFalse(app.staticTexts["Trust for this project"].exists, "More Settings still lists per-project trust")
            dismissTopSheet(app)

            reveal(trusted)
            trusted.tap()
            XCTAssertTrue(app.staticTexts["Trust for this project"].waitForExistence(timeout: 30), app.debugDescription)
            keepScreenshot(app, name: "\(scheme)-trusted-projects")
        }

        tour("light")
        let add = app.buttons["trusted-projects-add"]
        reveal(add)
        add.tap()
        let folder = app.buttons.matching(NSPredicate(format: "label == %@", "added-project")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 60), app.debugDescription)
        keepScreenshot(app, name: "light-add-project-browser")
        folder.tap()
        let useCurrent = app.buttons["Use current folder"]
        XCTAssertTrue(waitForEnabled(useCurrent, timeout: 60), app.debugDescription)
        keepScreenshot(app, name: "light-add-project-chosen")
        useCurrent.tap()

        let row = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "added-project")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the added project is not listed: \(app.debugDescription)")
        XCTAssertEqual(row.value as? String, "0", "an added project must start untrusted")
        keepScreenshot(app, name: "light-add-project-added")
        let stored = try? JSONSerialization.jsonObject(with: Data(contentsOf: trustStore)) as? [String: Any]
        XCTAssertEqual(stored?.first { ($0.key as NSString).lastPathComponent == "added-project" }?.value as? Bool, false,
                       "the Gateway trust store must record the added project as not trusted: \(String(describing: stored))")
        dismissTopSheet(app) // Trusted Projects
        dismissTopSheet(app) // Settings

        XCUIDevice.shared.appearance = .dark
        tour("dark")
        reveal(add)
        add.tap()
        XCTAssertTrue(folder.waitForExistence(timeout: 60), app.debugDescription)
        keepScreenshot(app, name: "dark-add-project-browser")
    }
}
