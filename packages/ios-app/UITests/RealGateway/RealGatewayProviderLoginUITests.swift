import XCTest

extension RealGatewayPairAndChatUITests {
    /// A pending manual login is owned by its presentation, not a rebuilt row
    /// or a disposable socket. Success after both transitions proves the same
    /// Gateway prompt survived; the callback is deliberately fixture-only.
    @MainActor
    func testProviderLoginSurvivesSafariAndReconnect() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let app = launchApp()
        defer { app.terminate() }
        open(fixture.invitationLink())
        completeFirstRunSetup(app, inWorkspace: fixture.workspace)
        XCTAssertTrue(waitForHittable(app.buttons["dashboard.menu"], timeout: 90), app.debugDescription)
        app.buttons["dashboard.menu"].tap()
        app.buttons["Settings"].tap()
        let providers = app.buttons["settings-link-Model Providers"]
        XCTAssertTrue(waitForHittable(providers, timeout: 30), app.debugDescription)
        providers.tap()
        let connect = app.buttons["Connect Alpha Login Fixture"]
        for _ in 0..<12 where !connect.isHittable { app.swipeUp() }
        XCTAssertTrue(waitForHittable(connect, timeout: 30), app.debugDescription)
        connect.tap()
        let code = app.textFields["Fixture OAuth code"]
        XCTAssertTrue(code.waitForExistence(timeout: 30), app.debugDescription)
        code.tap(); code.typeText("fixture-code#fixture-state")
        returnFromAnotherApp(app)
        XCTAssertTrue(code.waitForExistence(timeout: 15), "Safari return dismissed the pending provider sheet: \(app.debugDescription)")
        XCTAssertEqual(code.value as? String, "fixture-code#fixture-state")
        try forceReconnect(fixture)
        XCTAssertTrue(code.waitForExistence(timeout: 15), "Reconnect dismissed the pending provider sheet: \(app.debugDescription)")
        XCTAssertEqual(code.value as? String, "fixture-code#fixture-state")
        keepScreenshot(app, name: "1600-provider-login-after-safari-and-reconnect")
        app.buttons["Save"].tap()
        let details = app.buttons["Details for Alpha Login Fixture"]
        for _ in 0..<12 where !details.isHittable { app.swipeDown() }
        XCTAssertTrue(waitForHittable(details, timeout: 30), "The retained prompt did not complete: \(app.debugDescription)")
        details.tap()
        let remove = app.buttons["Clear Login Information"]
        // Reopening reads the real Gateway's persisted configured credential.
        XCTAssertTrue(remove.waitForExistence(timeout: 15), app.debugDescription)
        remove.tap()
        for _ in 0..<12 where !connect.isHittable { app.swipeUp() }
        XCTAssertTrue(waitForHittable(connect, timeout: 30), app.debugDescription)
        connect.tap()
        XCTAssertTrue(code.waitForExistence(timeout: 30), "Removing fixture credentials must permit a new login")
        XCTAssertEqual(code.value as? String, "Fixture OAuth code", "A successor must not inherit the old code")
        returnFromAnotherApp(app)
        XCTAssertTrue(code.waitForExistence(timeout: 15))
        code.tap(); code.typeText("fixture-code#fixture-state")
        app.buttons["Save"].tap()
        for _ in 0..<12 where !details.isHittable { app.swipeDown() }
        XCTAssertTrue(waitForHittable(details, timeout: 30), "Fixture relogin failed")
    }

}
