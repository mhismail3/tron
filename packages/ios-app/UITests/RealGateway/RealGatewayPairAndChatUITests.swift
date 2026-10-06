import Foundation
import XCTest

/// Real-UI journeys against the real Gateway fixture.
///
/// The app under test is launched with no fixture argument, so the hosted app's
/// no-fixture arm renders `ProductionSceneRoot`: the production scene, its
/// lifecycle modifiers and a real `AppModel` with a real `GatewayClient`. The
/// invitation link points at the fixture's fault-proxy port, so every byte of
/// the journey crosses the harness proxy. `scripts/ios-gateway-e2e-test run-ui`
/// patches `TRON_E2E_*` into this UI-test runner and refuses to report a journey
/// green unless exactly one case executed and passed.
///
/// Failure modes these journeys target, written before the code:
///
/// 1. The production pairing path accepts a code the Gateway rejects, so the
///    negative control would pass too and prove nothing.
/// 2. The scene renders a placeholder instead of the fixture's reply; the faux
///    provider's unique text makes that observable from the real interface.
/// 3. The scene's background transition does not retire the device's socket, or
///    the foreground does not reconnect: the harness asserts the Gateway's own
///    log shows a second connection for the journey that backgrounds the app.
/// 4. A background/foreground round trip loses the conversation the Gateway owns.
/// 5. The journey cannot reach the fixture at all and skips, which the harness
///    must not accept as a passing cross-layer receipt.
///
/// Pairing uses the production invitation link (`tron://pair?…`) through
/// `XCUIApplication.open`, the path a QR code or a shared link takes. The link is
/// handled by the shared production scene, so it is available with or without a
/// fixture argument.
final class RealGatewayPairAndChatUITests: XCTestCase {
    /// The prompt this journey sends; its text is asserted from the transcript.
    private let prompt = "Fixture journey: verify the real Gateway round trip"
    /// The first tokens the faux provider streams, so the reply is readable while
    /// the fixture is still delivering it.
    private let replyPrefix = "Streaming response starts now"
    /// The last tokens of the fixture's first faux response.
    private let replyCompletion = "Detached response complete"

    override func tearDown() {
        // A journey pairs the app for real, and the lane's app container is
        // shared with the hosted unit lane in this worktree: a pairing left
        // behind makes the next unit run's mounted-view tests time out waiting
        // for requests they never issue (A/B/A measured on the lane). The app's
        // own HOSTED_TEST reset returns it to the unpaired launch state every
        // hosted UI test already starts from, after a pass and after a failure.
        MainActor.assumeIsolated(RealGatewayUIHost.resetHostedAppState)
        super.tearDown()
    }

    @MainActor
    func testInvitationLinkPairsCompletesSetupStreamsAndReconnectsAfterBackground() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let app = launchApp()
        defer { app.terminate() }
        open(fixture.invitationLink())
        completeFirstRunSetup(app, inWorkspace: fixture.workspace)
        XCTAssertTrue(
            waitForHittable(app.buttons["dashboard.menu"], timeout: 90),
            "the invitation link and setup did not reach the dashboard: \(app.debugDescription)"
        )
        createSession(app, inWorkspace: fixture.workspace)

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

        // The fixture streams a few tokens a second, so the reply is read while
        // the fixture is still delivering it and again when it completes. The
        // transcript's partial label is not a stable XCUI observation - one poll
        // can land only on the completed row - so the trace is retained as
        // evidence instead of being asserted, and the reply the fixture sent must
        // be rendered.
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
        let trace = XCTAttachment(string: observations.joined(separator: "\n---\n"))
        trace.name = "424-real-ui-streamed-reply-observations"
        trace.lifetime = .keepAlways
        add(trace)
        XCTAssertTrue(
            observations.last?.contains(replyCompletion) == true,
            "the fixture's streamed reply never completed; observed: \(observations)"
        )
        keepScreenshot(app, name: "424-real-ui-pair-prompt-streamed-reply")

        // A real background and foreground, the transitions a phone performs.
        // The app must reach a background session before it is activated again,
        // which is what retires the socket and reconnects (the harness asserts
        // that second connection from the Gateway's own log).
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(
            waitForBackground(app, timeout: 60),
            "the app never reached a background session: \(app.state.rawValue)"
        )
        app.activate()
        XCTAssertTrue(
            waitForForeground(app, timeout: 90),
            "the app never returned to the foreground: \(app.state.rawValue)"
        )
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "real Gateway round trip")).firstMatch
                .waitForExistence(timeout: 90),
            "the prompt left the transcript across background/foreground: \(app.debugDescription)"
        )
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", replyCompletion)).firstMatch
                .waitForExistence(timeout: 90),
            "the reply left the transcript across background/foreground: \(app.debugDescription)"
        )
        keepScreenshot(app, name: "424-real-ui-conversation-after-background")
    }

    @MainActor
    func testWrongPairingCodeLinkIsRefusedAndThenTheFixtureLinkPairs() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        // A code of the right shape the Gateway can still refuse: its enrollment
        // alphabet has no `0`, so this can never be the fixture's own code.
        let wrongCode = String(repeating: "0", count: fixture.code.count)
        let app = launchApp()
        defer { app.terminate() }
        open(fixture.invitationLink(code: wrongCode))
        // The refusal is a transient card, so it is read as it appears; the
        // assertion then names what the app actually told the user. The card is
        // the app's own report of a refused pairing, and only a refused pairing
        // produces it: an accepted code would pair instead and never show it.
        let refusal = firstNoticeLabel(app, timeout: 60)
        XCTAssertEqual(
            refusal, "Pairing code is invalid",
            "the rejected invitation must report the Gateway's own failure"
        )
        keepScreenshot(app, name: "424-real-ui-wrong-pairing-code")

        // The same link and address with the fixture's own code must then pair,
        // so the control cannot pass by being a broken address: a paired device
        // that has not finished setup leaves the pairing step for its workspace
        // step, which only a connected Gateway reaches.
        open(fixture.invitationLink())
        XCTAssertTrue(
            app.buttons["Choose workspace"].waitForExistence(timeout: 90),
            "the fixture's own code must pair through the same link: \(app.debugDescription)"
        )
        keepScreenshot(app, name: "424-real-ui-accepted-code-pairs")
    }

    // MARK: - The production path

    /// Launches the hosted app with no fixture argument and no setup: the state
    /// a user's first launch has, which the journey then drives through the
    /// production scene.
    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--tron-reset-ui-test-state",
            "-ApplePersistenceIgnoreState",
            "YES",
        ]
        app.launch()
        return app
    }

    /// First-run setup, driven the way a user drives it: the invitation link has
    /// already paired the Mac, so the setup sheet stands on its workspace step,
    /// where the fixture's own folder is chosen from the Mac through the sheet's
    /// browser. That choice is what teaches the app the workspace a new session
    /// starts in, so the journey never depends on when a read lands.
    @MainActor
    private func completeFirstRunSetup(_ app: XCUIApplication, inWorkspace workspace: String) {
        let choose = app.buttons["Choose workspace"]
        XCTAssertTrue(
            choose.waitForExistence(timeout: 90),
            "the setup sheet never reached its workspace step: \(app.debugDescription)"
        )
        choose.tap()
        let folderName = workspace.split(separator: "/").last.map(String.init) ?? workspace
        let folder = app.buttons.matching(NSPredicate(format: "label == %@", folderName)).firstMatch
        XCTAssertTrue(
            folder.waitForExistence(timeout: 60),
            "the folder browser never listed \(workspace): \(app.debugDescription)"
        )
        folder.tap()
        let useCurrentFolder = app.buttons["Use current folder"]
        XCTAssertTrue(
            waitForEnabled(useCurrentFolder, timeout: 60),
            "the folder browser never admitted \(workspace): \(app.debugDescription)"
        )
        useCurrentFolder.tap()
        XCTAssertTrue(
            app.buttons["Change workspace"].waitForExistence(timeout: 30),
            "the setup sheet did not take the chosen workspace: \(app.debugDescription)"
        )
        // The fixture workspace holds project resources, so the Gateway asks for
        // a trust decision; declining keeps project resources out of the journey.
        if app.buttons["Open Without Resources"].waitForExistence(timeout: 10) {
            app.buttons["Open Without Resources"].tap()
        }
        advanceSetup(app)
        let finish = app.buttons["Finish setup"]
        XCTAssertTrue(finish.waitForExistence(timeout: 60), "setup never reached its model step: \(app.debugDescription)")
        XCTAssertTrue(waitForEnabled(finish, timeout: 90), "the model step never selected a model: \(app.debugDescription)")
        finish.tap()
    }

    /// The four setup pages between the workspace step and the model step (the
    /// workspace step itself, Anthropic, OpenAI and other providers). Each one
    /// only has to become complete; the fixture has no provider credentials to add.
    @MainActor
    private func advanceSetup(_ app: XCUIApplication) {
        for step in 0..<4 {
            let next = app.buttons["Next"]
            XCTAssertTrue(
                waitForEnabled(next, timeout: 60),
                "setup page \(step + 1) after the workspace never became complete: \(app.debugDescription)"
            )
            next.tap()
        }
    }

    /// Hands the running app a link the way the system does, which is the path a
    /// QR code or a shared invitation takes. Opening it through the system rather
    /// than `XCUIApplication.open` keeps this launch's arguments, so the state
    /// above survives the link.
    @MainActor
    private func open(_ link: String) {
        XCUIDevice.shared.system.open(URL(string: link)!)
    }

    /// A new session in the workspace first-run setup chose, as the dashboard
    /// offers it. The setup step assigned that workspace to the model, so the
    /// sheet starts from it without waiting for any read.
    @MainActor
    private func createSession(_ app: XCUIApplication, inWorkspace workspace: String) {
        let menu = app.buttons["dashboard.menu"]
        XCTAssertTrue(waitForEnabled(menu, timeout: 90), "the dashboard menu never became usable: \(app.debugDescription)")
        menu.tap()
        let newSession = app.buttons["New Session"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 30), app.debugDescription)
        newSession.tap()
        let card = app.buttons["new-session-card.Workspace"]
        XCTAssertTrue(card.waitForExistence(timeout: 60), app.debugDescription)
        let expected = workspace.split(separator: "/").suffix(2).joined(separator: "/")
        let showsWorkspace = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", expected), object: card
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [showsWorkspace], timeout: 90), .completed,
            "the new session must start in the workspace setup chose (\(workspace)): \(card.label)"
        )
        let create = app.buttons["Create"]
        XCTAssertTrue(create.waitForExistence(timeout: 60), app.debugDescription)
        XCTAssertTrue(waitForEnabled(create, timeout: 90), "session creation never became ready: \(app.debugDescription)")
        create.tap()
    }

    /// The first announced notice text, read while the card is still presented.
    /// Notices auto-dismiss, so a snapshot taken after a bounded wait can no
    /// longer see them.
    @MainActor
    private func firstNoticeLabel(_ app: XCUIApplication, timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let card = app.descendants(matching: .any).matching(identifier: "in-app-notice-card").firstMatch
            if card.exists, !card.label.isEmpty { return card.label }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }

    /// Waits for the app to leave the foreground: the system must report a
    /// background session, not merely an inactive scene, because only the
    /// background transition retires the device's socket. The state is passively
    /// monitored, so this waits through an expectation: polling it from here
    /// would starve the session that reports it.
    @MainActor
    private func waitForBackground(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let background = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "state == %d OR state == %d",
                XCUIApplication.State.runningBackground.rawValue,
                XCUIApplication.State.runningBackgroundSuspended.rawValue
            ),
            object: app
        )
        return XCTWaiter().wait(for: [background], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForForeground(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let foreground = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "state == %d", XCUIApplication.State.runningForeground.rawValue),
            object: app
        )
        return XCTWaiter().wait(for: [foreground], timeout: timeout) == .completed
    }

    private func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)
        return XCTWaiter().wait(for: [enabled], timeout: timeout) == .completed
    }

    /// Waits for an element the user can actually touch. A dashboard control is
    /// present while a sheet covers it, so this is what separates the paired
    /// scene from a sheet that is still asking to pair.
    @MainActor
    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: element)
        return XCTWaiter().wait(for: [hittable], timeout: timeout) == .completed
    }

    @MainActor
    private func keepScreenshot(_ app: XCUIApplication, name: String) {
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = name
        capture.lifetime = .keepAlways
        add(capture)
    }
}

/// The hosted app's own state, for the journeys that leave it paired.
@MainActor
private enum RealGatewayUIHost {
    /// Returns the hosted app to the state a hosted UI test starts from: no
    /// paired Mac, no completed setup, no workspace default.
    static func resetHostedAppState() {
        let app = XCUIApplication()
        app.launchArguments = ["--tron-reset-ui-test-state", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        app.terminate()
    }
}

/// The real Gateway fixture `scripts/ios-gateway-e2e-test run-ui` provides to
/// this runner. The runner receives the fixture's port and one-time code, and the
/// harness seeds the app's own state before the journey starts.
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

    /// The production invitation link, addressed at the fixture's fault proxy so
    /// every byte of the pairing and of the session crosses it.
    func invitationLink(code: String? = nil) -> String {
        "tron://pair?host=\(host)&port=\(port)&code=\(code ?? self.code)"
    }
}
