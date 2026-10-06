import Foundation
import XCTest

/// Real-UI journeys against the real Gateway fixture.
///
/// The app under test is launched with no fixture argument, so the production
/// scene runs with a real `AppModel` and `GatewayClient`; the pairing address is
/// the fixture's fault-proxy port, so every byte of the journey crosses the
/// harness proxy. `scripts/ios-gateway-e2e-test run-ui` patches `TRON_E2E_*` into
/// this UI-test runner and refuses to report a journey green unless exactly one
/// case executed and passed.
///
/// Failure modes these journeys target, written before the code:
///
/// 1. The production pairing form accepts a code the Gateway rejects, so the
///    negative control would pass too and prove nothing.
/// 2. The scene renders a placeholder instead of the fixture's reply; the faux
///    provider's unique text makes that observable from the real interface.
/// 3. A background/foreground round trip loses the conversation the Gateway owns.
/// 4. The journey cannot reach the fixture at all and skips, which the harness
///    must not accept as a passing cross-layer receipt.
///
/// Pairing uses the onboarding form rather than `XCUIApplication.open(tron://pair…)`:
/// the deep-link handler is attached to the production scene only (the `#else`
/// arm of `TronMobileApp`), and the hosted app this lane builds has none, so
/// `open` would deliver the URL nowhere. Adding a handler there would be a
/// test-only production hook (AGENTS rule 6). Entering the Mac's host, port and
/// one-time code is the production path for a user without a QR code, and it
/// drives the same `AppModel.pair` invitation the link does.
final class RealGatewayPairAndChatUITests: XCTestCase {
    /// The prompt this journey sends; its text is asserted from the transcript.
    private let prompt = "Fixture journey: verify the real Gateway round trip"
    /// The first tokens the faux provider streams, so the reply is observable
    /// while it is still incomplete.
    private let replyPrefix = "Streaming response starts now"
    /// The last tokens of the fixture's first faux response.
    private let replyCompletion = "Detached response complete"

    @MainActor
    func testPairsByLinkStreamsAndSurvivesBackground() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let app = launchApp(fixture)
        defer { app.terminate() }
        pair(app, host: fixture.host, port: String(fixture.port), code: fixture.code)
        XCTAssertTrue(
            app.buttons["dashboard.menu"].waitForExistence(timeout: 90),
            "pairing did not reach the production scene: \(app.debugDescription)"
        )
        createSession(app, defaultWorkspace: fixture.workspace)

        let composer = app.textViews["Message input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 60), app.debugDescription)
        composer.tap()
        composer.typeText(prompt)
        // The trailing control becomes the send action only once the composer
        // holds sendable content, so it appears after the prompt is typed.
        let send = app.buttons["Send message"]
        XCTAssertTrue(send.waitForExistence(timeout: 60), "the send control never appeared: \(app.debugDescription)")
        XCTAssertTrue(waitForEnabled(send, timeout: 60), "the composer never accepted the prompt: \(app.debugDescription)")
        send.tap()

        let sent = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "real Gateway round trip")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 60), "the sent prompt is not in the transcript: \(app.debugDescription)")

        // The fixture streams at eight tokens a second, so the reply is observed
        // while it is incomplete and again when it completes. Both are read from
        // the one transcript element, never from a test-owned projection.
        var observations: [String] = []
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            let element = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", replyPrefix)).firstMatch
            if element.exists, !element.label.isEmpty, element.label != observations.last {
                observations.append(element.label)
            }
            if observations.last?.contains(replyCompletion) == true { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(
            observations.last?.contains(replyCompletion) == true,
            "the fixture's streamed reply never completed; observed: \(observations)"
        )
        let streamedIncrementally = observations.contains { earlier in
            guard let final = observations.last, earlier.count < final.count else { return false }
            return final.hasPrefix(earlier)
        }
        XCTAssertTrue(
            streamedIncrementally,
            "the reply appeared without any partial delivery; observed: \(observations)"
        )
        keepScreenshot(app, name: "424-real-ui-pair-prompt-streamed-reply")

        // Background and foreground are the real system transitions the phone
        // performs, so the conversation must survive them intact.
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "real Gateway round trip")).firstMatch
                .waitForExistence(timeout: 90),
            "the prompt left the transcript across background/foreground: \(app.debugDescription)"
        )
        let restored = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", replyCompletion)).firstMatch
        XCTAssertTrue(
            restored.waitForExistence(timeout: 90),
            "the reply left the transcript across background/foreground: \(app.debugDescription)"
        )
        keepScreenshot(app, name: "424-real-ui-conversation-after-background")
    }

    @MainActor
    func testWrongPairingCodeReportsClearFailure() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        // A first-run device, as in the journey above: the pairing sheet owns the
        // error while an attempt is in flight, so the refusal is announced and
        // stays presented exactly as the user sees it. A device that has already
        // finished setup re-presents that sheet as the attempt starts, which
        // retires the announcement with the sheet that owned it.
        let app = launchApp(fixture, setupComplete: false)
        defer { app.terminate() }
        // A code of the right shape the Gateway can still refuse: its enrollment
        // alphabet has no `0`, so this can never be the fixture's own code.
        pair(app, host: fixture.host, port: String(fixture.port), code: String(repeating: "0", count: fixture.code.count))
        // The refusal is a transient card, so it is read as it appears; the
        // assertion then names what the app actually told the user.
        let refusal = firstNoticeLabel(app, timeout: 60)
        XCTAssertEqual(
            refusal, "Pairing code is invalid",
            "the rejected pairing must report the Gateway's own failure"
        )
        XCTAssertFalse(app.buttons["Next"].exists, "a refused code must not advance setup: \(app.debugDescription)")
        XCTAssertTrue(app.buttons["Connect to Mac"].isEnabled, "a refused code must leave the form usable: \(app.debugDescription)")
        keepScreenshot(app, name: "424-real-ui-wrong-pairing-code")

        // The same form, address and port with the fixture's own code must then
        // pair, so the refused code is the only difference this control drives:
        // without this the control could be a broken address instead.
        replaceText(app.secureTextFields["One-time code"], with: fixture.code)
        let connect = app.buttons["Connect to Mac"]
        XCTAssertTrue(waitForEnabled(connect, timeout: 30), app.debugDescription)
        connect.tap()
        XCTAssertTrue(
            connect.waitForNonExistence(timeout: 90),
            "the fixture's own code must leave the pairing page: \(app.debugDescription)"
        )
        XCTAssertTrue(
            app.buttons["Next"].waitForExistence(timeout: 30),
            "the fixture's own code must advance setup: \(app.debugDescription)"
        )
        keepScreenshot(app, name: "424-real-ui-accepted-code-advances-setup")
    }

    // MARK: - The production path

    private func launchApp(_ fixture: RealGatewayUIFixture, setupComplete: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        // The hosted test app is unpaired after `--tron-reset-ui-test-state`
        // (HOSTED_TEST only). A completed setup plus the fixture workspace puts
        // the device in the state of a user who already finished first-run setup
        // and is pairing this Mac, so the journey reaches the conversation rather
        // than the setup pages. With `setupComplete` off the app is a first-run
        // device instead, which is where the pairing sheet owns an attempt's
        // error while it is in flight.
        app.launchArguments = [
            "--tron-reset-ui-test-state",
            "-ApplePersistenceIgnoreState", "YES",
            "-tronSetupComplete.v1", setupComplete ? "YES" : "NO",
            "-defaultWorkspace.v1", fixture.workspace,
        ]
        app.launch()
        return app
    }

    /// Walks the real onboarding sheet to its manual pairing form and connects.
    private func pair(_ app: XCUIApplication, host: String, port: String, code: String) {
        let next = app.buttons["Next"]
        XCTAssertTrue(next.waitForExistence(timeout: 90), "the first-run pairing sheet never presented: \(app.debugDescription)")
        for step in 0..<3 {
            XCTAssertTrue(next.waitForExistence(timeout: 30), "onboarding step \(step) lost its Next action: \(app.debugDescription)")
            next.tap()
        }
        let manual = app.buttons["Enter Manually"]
        XCTAssertTrue(manual.waitForExistence(timeout: 30), app.debugDescription)
        manual.tap()
        replaceText(app.textFields["Tailscale host"], with: host)
        replaceText(app.textFields["Port"], with: port)
        let codeField = app.secureTextFields["One-time code"]
        XCTAssertTrue(codeField.waitForExistence(timeout: 30), app.debugDescription)
        codeField.tap()
        codeField.typeText(code)
        // A secure field reports its own masked length, so a truncated entry is
        // named here instead of surfacing as the form's generic refusal.
        XCTAssertEqual(
            (codeField.value as? String)?.count, code.count,
            "the pairing form did not receive the whole one-time code: \(app.debugDescription)"
        )
        let connect = app.buttons["Connect to Mac"]
        XCTAssertTrue(waitForEnabled(connect, timeout: 30), "the pairing form never became submittable: \(app.debugDescription)")
        connect.tap()
    }

    /// The first announced notice text, read while the card is still presented.
    /// Notices auto-dismiss, so a snapshot taken after a bounded wait can no
    /// longer see them.
    private func firstNoticeLabel(_ app: XCUIApplication, timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let card = app.descendants(matching: .any).matching(identifier: "in-app-notice-card").firstMatch
            if card.exists, !card.label.isEmpty { return card.label }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }

    /// A new session on the fixture's own workspace, as the dashboard offers it.
    private func createSession(_ app: XCUIApplication, defaultWorkspace: String) {
        let menu = app.buttons["dashboard.menu"]
        XCTAssertTrue(waitForEnabled(menu, timeout: 90), "the dashboard menu never became usable: \(app.debugDescription)")
        menu.tap()
        let newSession = app.buttons["New Session"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 30), app.debugDescription)
        newSession.tap()
        let workspace = app.buttons["new-session-card.Workspace"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 60), app.debugDescription)
        let expected = defaultWorkspace.split(separator: "/").suffix(2).joined(separator: "/")
        XCTAssertTrue(
            workspace.label.contains(expected),
            "the new session must default to the fixture workspace \(defaultWorkspace): \(workspace.label)"
        )
        let create = app.buttons["Create"]
        XCTAssertTrue(create.waitForExistence(timeout: 60), app.debugDescription)
        XCTAssertTrue(waitForEnabled(create, timeout: 90), "session creation never became ready: \(app.debugDescription)")
        create.tap()
    }

    private func replaceText(_ field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 30), "the pairing form did not present \(field)")
        field.tap()
        if let current = field.value as? String, !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(text)
    }

    private func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)
        return XCTWaiter().wait(for: [enabled], timeout: timeout) == .completed
    }

    private func keepScreenshot(_ app: XCUIApplication, name: String) {
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = name
        capture.lifetime = .keepAlways
        add(capture)
    }
}

/// The real Gateway fixture `scripts/ios-gateway-e2e-test run-ui` provides to
/// this runner. The app under test receives a launch argument for the workspace
/// only; the fixture's port and one-time code are the journey's inputs.
private struct RealGatewayUIFixture {
    let host = "127.0.0.1"
    let port: Int
    let code: String
    let workspace: String

    static func fromEnvironment() throws -> RealGatewayUIFixture {
        let environment = ProcessInfo.processInfo.environment
        guard let portText = environment["TRON_E2E_PORT"], let port = Int(portText),
              let code = environment["TRON_E2E_CODE"],
              let workspace = environment["TRON_E2E_WORKSPACE"] else {
            throw XCTSkip("Run through scripts/ios-gateway-e2e-test run-ui to provide the real Gateway fixture.")
        }
        return RealGatewayUIFixture(port: port, code: code, workspace: workspace)
    }
}
