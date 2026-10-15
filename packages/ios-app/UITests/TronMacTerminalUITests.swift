import XCTest

/// Mac Terminal from Settings against a real OpenSSH sshd on this Mac's
/// Tailscale address (`scripts/ios-mac-terminal-journey` starts it and names
/// its description in `TRON_MAC_TERMINAL_FIXTURE`). The Gateway is synthetic
/// and only answers enrollment; the key, the SSH client, the PTY and the shell
/// are real. Shell side effects land in a marker file beside the description,
/// which the test reads back, so typed input, the Control key and resize are
/// proved by the Mac, not by the screen.
final class TronMacTerminalUITests: XCTestCase {
    private var configuration: URL!
    private var marker: URL { configuration.deletingLastPathComponent().appendingPathComponent("marker.txt") }
    private var authorizedKeys: URL { configuration.deletingLastPathComponent().appendingPathComponent("authorized_keys") }

    override func setUpWithError() throws {
        continueAfterFailure = false
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["TRON_MAC_TERMINAL_FIXTURE"],
                                 "Run through scripts/ios-mac-terminal-journey, which starts the sshd")
        configuration = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: marker)
    }

    @MainActor
    func testEnrollTypeControlResizeAndKeepWorkingWithoutTheGateway() throws {
        let app = launch(scenario: "enroll")
        defer { app.terminate() }
        openMacTerminal(app)
        XCTAssertTrue(app.staticTexts["Open a shell on your Mac"].waitForExistence(timeout: 15), app.debugDescription)
        try capture(app, "setup")
        app.buttons["Enable Mac Terminal"].tap()
        waitForPhase(app, "Connected")
        let keys = try String(contentsOf: authorizedKeys, encoding: .utf8)
        XCTAssertTrue(keys.contains("ecdsa-sha2-nistp256 "), keys)

        focusTerminal(app)
        app.typeText("echo TRON_UI_$((6*7)) > \(marker.path); stty size >> \(marker.path)\n")
        try waitForMarker(containing: "TRON_UI_42")
        // The emulator sized the PTY to the sheet: the Mac reports the
        // emulator's rows and columns, not the 80x24 the shell opened with.
        let size = try String(contentsOf: marker, encoding: .utf8).split(separator: "\n").last.map(String.init) ?? ""
        XCTAssertNotEqual(size, "24 80", "resize did not reach the PTY")
        // Control-C through the control bar interrupts a running command.
        app.typeText("sleep 60\n")
        app.buttons["Control modifier"].tap()
        app.typeText("c")
        app.typeText("echo INTERRUPTED >> \(marker.path)\n")
        try waitForMarker(containing: "INTERRUPTED", timeout: 20)
        try capture(app, "connected")

        // The Gateway goes away; a new shell still opens straight to the Mac.
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.tron.mobile.fixture.mac-terminal.stop-gateway" as CFString), nil, nil, true)
        app.buttons["Mac Terminal options"].tap()
        app.buttons["New Shell"].tap()
        waitForPhase(app, "Connected")
        focusTerminal(app)
        app.typeText("echo GATEWAY_DOWN >> \(marker.path)\n")
        try waitForMarker(containing: "GATEWAY_DOWN")
        try capture(app, "gateway-down")

        // Removing the key changes the Mac, so without the Gateway it refuses
        // and says how to revoke on the Mac instead.
        app.buttons["Mac Terminal options"].tap()
        app.buttons["Remove Mac Terminal"].tap()
        app.alerts.buttons["Remove"].tap()
        XCTAssertTrue(app.alerts.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "needs the Gateway")).firstMatch
            .waitForExistence(timeout: 10), app.debugDescription)
        try capture(app, "remove-needs-gateway")
    }

    @MainActor
    func testRemoveRevokesTheKeyOnTheMac() throws {
        let app = launch(scenario: "enroll")
        defer { app.terminate() }
        openMacTerminal(app)
        app.buttons["Enable Mac Terminal"].tap()
        waitForPhase(app, "Connected")
        app.buttons["Mac Terminal options"].tap()
        app.buttons["Remove Mac Terminal"].tap()
        app.alerts.buttons["Remove"].tap()
        XCTAssertTrue(app.staticTexts["Open a shell on your Mac"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(try String(contentsOf: authorizedKeys, encoding: .utf8), "")
    }

    @MainActor
    func testRemoteLoginOffSaysHowToTurnItOnThenEnrolls() throws {
        let app = launch(scenario: "remote-login-off")
        defer { app.terminate() }
        openMacTerminal(app)
        XCTAssertTrue(app.staticTexts["Turn on Remote Login"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "General › Sharing")).firstMatch.exists)
        try capture(app, "remote-login-off")
        app.buttons["Check Again"].tap()
        app.buttons["Enable Mac Terminal"].tap()
        waitForPhase(app, "Connected")
    }

    @MainActor
    func testHostKeyMismatchNeverConnects() throws {
        let app = launch(scenario: "mismatch")
        defer { app.terminate() }
        openMacTerminal(app)
        app.buttons["Enable Mac Terminal"].tap()
        XCTAssertTrue(app.staticTexts["Mac Terminal unavailable"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "different SSH host key")).firstMatch.exists)
        waitForPhase(app, "Unavailable")
        try capture(app, "host-key-mismatch")
    }

    @MainActor
    private func launch(scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-mac-terminal-fixture", "-mac-terminal-scenario", scenario]
        app.launchEnvironment["TRON_MAC_TERMINAL_FIXTURE"] = configuration.path
        app.launch()
        return app
    }

    @MainActor
    private func openMacTerminal(_ app: XCUIApplication) {
        let row = app.buttons["settings-link-Mac Terminal"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), app.debugDescription)
        // Tools & Diagnostics is the last Settings group (#1030).
        for _ in 0..<12 where !row.isHittable { app.swipeUp() }
        row.tap()
    }

    @MainActor
    private func waitForPhase(_ app: XCUIApplication, _ phase: String) {
        let title = app.descendants(matching: .any)["terminal-sheet-title"].firstMatch
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", phase), object: title)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 30), .completed, app.debugDescription)
    }

    @MainActor
    private func focusTerminal(_ app: XCUIApplication) {
        // The emulator fills the sheet; a tap in it takes the keyboard.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        XCTAssertTrue(app.buttons["Control modifier"].waitForExistence(timeout: 10), app.debugDescription)
    }

    private func waitForMarker(containing text: String, timeout: TimeInterval = 15) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let contents = try? String(contentsOf: marker, encoding: .utf8), contents.contains(text) { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTFail("The Mac never ran the typed command: \(text) not in \((try? String(contentsOf: marker, encoding: .utf8)) ?? "no marker")")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) throws {
        let image = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = "983-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["TRON_MAC_TERMINAL_CAPTURE_DIR"] {
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try image.pngRepresentation.write(to: root.appendingPathComponent("\(name).png"), options: .atomic)
        }
    }
}
