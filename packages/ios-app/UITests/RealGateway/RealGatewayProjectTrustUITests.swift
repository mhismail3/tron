import Foundation
import XCTest

extension RealGatewayPairAndChatUITests {
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
