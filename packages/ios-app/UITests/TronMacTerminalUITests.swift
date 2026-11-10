import XCTest

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
        trustHost(app)
        waitForPhase(app, "Connected")
        let keys = try String(contentsOf: authorizedKeys, encoding: .utf8)
        XCTAssertTrue(keys.contains("ecdsa-sha2-nistp256 "), keys)

        focusTerminal(app)
        app.typeText("echo TRON_UI_$((6*7)) > \(marker.path); stty size >> \(marker.path)\n")
        try waitForMarker(containing: "TRON_UI_42")
        let size = try String(contentsOf: marker, encoding: .utf8).split(separator: "\n").last.map(String.init) ?? ""
        XCTAssertNotEqual(size, "24 80", "resize did not reach the PTY")
        app.typeText("sleep 60\n")
        app.buttons["Control modifier"].tap()
        app.typeText("c")
        app.typeText("echo INTERRUPTED >> \(marker.path)\n")
        try waitForMarker(containing: "INTERRUPTED", timeout: 20)
        try capture(app, "connected")

        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.tron.mobile.fixture.mac-terminal.stop-gateway" as CFString), nil, nil, true)
        app.buttons["Mac Terminal options"].tap()
        app.buttons["Reconnect"].tap()
        waitForPhase(app, "Connected")
        focusTerminal(app)
        app.typeText("echo GATEWAY_DOWN >> \(marker.path)\n")
        try waitForMarker(containing: "GATEWAY_DOWN")
        try capture(app, "gateway-down")

        app.buttons["Mac Terminal options"].tap()
        app.buttons["Remove Mac Terminal"].tap()
        app.buttons["Remove"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "needs the Gateway")).firstMatch
            .waitForExistence(timeout: 10), app.debugDescription)
        try capture(app, "remove-needs-gateway")
    }

    @MainActor
    func testShellAndOutputSurviveDismissAndBackground() throws {
        let app = launch(scenario: "enroll")
        defer { app.terminate() }
        openMacTerminal(app)
        app.buttons["Enable Mac Terminal"].tap()
        trustHost(app)
        waitForPhase(app, "Connected")
        focusTerminal(app)
        app.typeText("echo \"one=$$\" >> \(marker.path); echo SHELL_ONE_$((6*7))\n")
        let pid = try markerValue("one")
        waitForEmulator(app, containing: "SHELL_ONE_42")
        try capture(app, "persist-before-dismiss")

        app.navigationBars.buttons["Done"].firstMatch.tap()
        let row = app.buttons["settings-link-Mac Terminal"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        row.tap()
        waitForEmulator(app, containing: "SHELL_ONE_42")
        waitForPhase(app, "Connected")
        try capture(app, "persist-after-reopen")
        focusTerminal(app)
        app.typeText("echo \"again=$$\" >> \(marker.path)\n")
        XCTAssertEqual(try markerValue("again"), pid, "reopening reached a different shell")

        app.typeText("sleep 4; echo LATE_$((7*7))\n")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 8)
        app.activate()
        waitForEmulator(app, containing: "LATE_49")
        waitForPhase(app, "Connected")
        focusTerminal(app)
        app.typeText("echo \"back=$$\" >> \(marker.path)\n")
        XCTAssertEqual(try markerValue("back"), pid, "returning from the background reached a different shell")
        try capture(app, "persist-after-background")
    }

    @MainActor
    func testRemoveRevokesTheKeyOnTheMac() throws {
        let app = launch(scenario: "enroll")
        defer { app.terminate() }
        openMacTerminal(app)
        app.buttons["Enable Mac Terminal"].tap()
        trustHost(app)
        waitForPhase(app, "Connected")
        app.buttons["Mac Terminal options"].tap()
        app.buttons["Remove Mac Terminal"].tap()
        app.buttons["Remove"].tap()
        XCTAssertTrue(app.staticTexts["Open a shell on your Mac"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(try String(contentsOf: authorizedKeys, encoding: .utf8), "")
    }

    @MainActor
    func testPrivateServiceEnableRequiresTrustAndDeclinePublishesNoKey() throws {
        let app = launch(scenario: "enroll")
        defer { app.terminate() }
        openMacTerminal(app)
        app.buttons["Enable Mac Terminal"].tap()
        XCTAssertTrue(app.buttons["Trust and Enroll"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.staticTexts["mac-terminal-host-fingerprint"].exists)
        XCTAssertEqual(try String(contentsOf: authorizedKeys, encoding: .utf8), "")
        try capture(app, "host-trust")
        app.buttons["Decline"].tap()
        XCTAssertTrue(app.buttons["Enable Mac Terminal"].waitForExistence(timeout: 15))
        XCTAssertEqual(try String(contentsOf: authorizedKeys, encoding: .utf8), "")
        app.buttons["Enable Mac Terminal"].tap()
        trustHost(app)
        waitForPhase(app, "Connected")
    }

    @MainActor
    func testFailedRemoveReconcilesPendingProfileSwitchWithoutLosingTheOldEnrollment() throws {
        let app = launch(scenario: "remove-profile-switch")
        defer { app.terminate() }
        let files = configuration.deletingLastPathComponent()
        openMacTerminal(app)
        app.buttons["Enable Mac Terminal"].tap()
        trustHost(app)
        waitForPhase(app, "Connected")
        focusTerminal(app)
        app.typeText("echo \"before=$$\" >> \(marker.path)\n")
        let originalPID = try markerValue("before")
        let originalAuthorization = try Data(contentsOf: authorizedKeys)
        app.buttons["Dismiss keyboard"].tap()
        app.buttons["Mac Terminal options"].tap()
        app.buttons["Remove Mac Terminal"].tap()
        app.buttons["Remove"].tap()
        let pending = files.appending(path: "removal-pending.txt")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: pending.path)
        }, object: nil)], timeout: 15), .completed)
        app.navigationBars.buttons["Done"].firstMatch.tap()
        postMacTerminalNotification("select-b")
        let selected = files.appending(path: "selected-machine.txt")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: selected, encoding: .utf8)) == "mac-terminal-machine-b"
        }, object: nil)], timeout: 15), .completed)
        openMacTerminal(app)
        postMacTerminalNotification("fail-removal")
        XCTAssertTrue(app.staticTexts["Open a shell on your Mac"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(try Data(contentsOf: authorizedKeys), originalAuthorization, "failed revocation changed the old Mac’s authorization")
        app.navigationBars.buttons["Done"].firstMatch.tap()
        postMacTerminalNotification("select-a")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: selected, encoding: .utf8)) == "mac-terminal-machine"
        }, object: nil)], timeout: 15), .completed)
        openMacTerminal(app)
        waitForPhase(app, "Connected")
        focusTerminal(app)
        app.typeText("echo \"after=$$\" >> \(marker.path)\n")
        XCTAssertEqual(try markerValue("after"), originalPID, "returning to A lost its enrollment or shell")
    }

    private func postMacTerminalNotification(_ suffix: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue: "com.tron.mobile.fixture.mac-terminal.\(suffix)" as CFString), nil, nil, true)
    }

    @MainActor
    func testHostKeyMismatchNeverConnects() throws {
        let app = launch(scenario: "mismatch")
        defer { app.terminate() }
        openMacTerminal(app)
        app.buttons["Enable Mac Terminal"].tap()
        trustHost(app)
        XCTAssertTrue(app.staticTexts["Mac Terminal unavailable"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "different SSH host key")).firstMatch.exists)
        waitForPhase(app, "Unavailable")
        try capture(app, "host-key-mismatch")
    }

    @MainActor
    private func trustHost(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["Trust and Enroll"].waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["Trust and Enroll"].tap()
    }

    @MainActor
    func testLightAndDarkSSHSession() throws {
        for light in [false, true] {
            let app = launch(scenario: "enroll", light: light)
            openMacTerminal(app)
            app.buttons["Enable Mac Terminal"].tap()
            trustHost(app)
            waitForPhase(app, "Connected")
            focusTerminal(app)
            let label = light ? "LIGHT" : "DARK"
            app.typeText("echo SSH_\(label)_$((6*7))\n")
            waitForEmulator(app, containing: "SSH_\(label)_42")
            app.buttons["Dismiss keyboard"].tap()
            try capture(app, light ? "ssh-terminal-light" : "ssh-terminal-dark")
            app.terminate()
        }
    }

    @MainActor
    private func launch(scenario: String, light: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-mac-terminal-fixture", "-mac-terminal-scenario", scenario]
            + (light ? ["-mac-terminal-light"] : [])
        app.launchEnvironment["TRON_MAC_TERMINAL_FIXTURE"] = configuration.path
        app.launch()
        return app
    }

    @MainActor
    private func openMacTerminal(_ app: XCUIApplication) {
        let row = app.buttons["settings-link-Mac Terminal"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), app.debugDescription)
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
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        XCTAssertTrue(app.buttons["Control modifier"].waitForExistence(timeout: 10), app.debugDescription)
        let typingTip = app.buttons["Continue"]
        if typingTip.exists { typingTip.tap() }
    }

    @MainActor
    private func emulatorText(_ app: XCUIApplication) -> String {
        let emulator = app.descendants(matching: .any)["terminal-emulator"].firstMatch
        return emulator.exists ? (emulator.value as? String ?? "") : ""
    }

    @MainActor
    private func waitForEmulator(_ app: XCUIApplication, containing text: String, timeout: TimeInterval = 20) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if emulatorText(app).contains(text) { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        try? capture(app, "failure-output")
        XCTFail("The terminal never showed \(text): \(emulatorText(app).suffix(600))\n\(app.debugDescription)")
    }

    private func markerValue(_ label: String) throws -> String {
        try waitForMarker(containing: "\(label)=")
        let contents = try String(contentsOf: marker, encoding: .utf8)
        let value = contents.split(separator: "\n").last { $0.hasPrefix("\(label)=") }?.dropFirst(label.count + 1)
        return try XCTUnwrap(value.map(String.init), contents)
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

final class TronMacTerminalLoadingUITests: XCTestCase {
    @MainActor
    func testLoadingSheetIsOneUniformBackground() throws {
        continueAfterFailure = true
        for scheme in ["dark", "light"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-mac-terminal-fixture", "-mac-terminal-scenario", "loading"]
                + (scheme == "light" ? ["-mac-terminal-light"] : [])
            app.launch()
            let row = app.buttons["settings-link-Mac Terminal"]
            XCTAssertTrue(row.waitForExistence(timeout: 15), app.debugDescription)
            for _ in 0..<12 where !row.isHittable { app.swipeUp() }
            row.tap()
            let title = app.descendants(matching: .any)["terminal-sheet-title"].firstMatch
            XCTAssertTrue(title.waitForExistence(timeout: 15), app.debugDescription)
            Thread.sleep(forTimeInterval: 2)
            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "mac-terminal-loading-\(scheme)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let window = app.windows.firstMatch.frame
            let top = title.frame.maxY + 120, bottom = window.maxY - 80
            let spread = try Self.lumaSpread(screenshot.image, x: window.width * 0.2, from: top, to: bottom, scale: window.width)
            XCTAssertLessThanOrEqual(spread, 4, "\(scheme): the loading sheet is not one uniform background (luma spread \(spread))")
            app.terminate()
        }
    }

    private static func lumaSpread(_ image: UIImage, x: CGFloat, from top: CGFloat, to bottom: CGFloat, scale width: CGFloat) throws -> Int {
        let cg = try XCTUnwrap(image.cgImage)
        let factor = CGFloat(cg.width) / width
        let (w, h) = (cg.width, cg.height)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let column = Int(x * factor)
        let lumas = stride(from: Int(top * factor), to: min(Int(bottom * factor), h), by: 3).map { y -> Int in
            let i = (y * w + column) * 4
            return (Int(pixels[i]) * 299 + Int(pixels[i + 1]) * 587 + Int(pixels[i + 2]) * 114) / 1000
        }
        return (lumas.max() ?? 0) - (lumas.min() ?? 0)
    }
}
