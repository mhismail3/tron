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
    private let prompt = "Fixture journey: verify the real Gateway round trip\n"
        + (1...18).map { "Continuity anchor line \($0): keep this conversation visible." }.joined(separator: "\n")
    /// The first tokens the faux provider streams, so the reply is readable while
    /// the fixture is still delivering it.
    private let replyPrefix = "Streaming response starts now"
    /// The last tokens of the fixture's first faux response.
    private let replyCompletion = "Detached response complete"

    override func tearDown() {
        // A journey pairs the app for real, and the lane's app container is
        // shared with the hosted UI lane in this worktree: a pairing left
        // behind makes the next hosted run's mounted-view tests time out waiting
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

        // Keep this route mounted: unlike navigating back to the dashboard,
        // retiring its transport must not retire the last installed transcript.
        let sameRouteReply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", replyCompletion)).firstMatch
        composer.tap()
        var unsentDraft = "Unsent recovery draft: keep every word and the keyboard."
        composer.typeText(unsentDraft)
        XCTAssertEqual(composer.value as? String, unsentDraft,
                       "the retained route must expose the complete unsent draft")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10),
                      "the composer keyboard must be present before transport retirement")
        let replyFrameBeforeLoss = sameRouteReply.frame
        let composerFrameBeforeLoss = composer.frame
        try setProxyMode(fixture, mode: "blackhole")
        defer { try? setProxyMode(fixture, mode: "pass") }
        XCTAssertTrue(app.staticTexts["Gateway connection unavailable"].waitForExistence(timeout: 60),
                      "the real transport did not retire: \(app.debugDescription)")
        XCTAssertTrue(sameRouteReply.exists, "connection retirement removed the mounted transcript")
        XCTAssertEqual(composer.value as? String, unsentDraft,
                       "transport retirement must preserve the entire unsent draft")
        XCTAssertTrue(app.keyboards.firstMatch.exists,
                      "transport retirement must not dismiss the active composer keyboard")
        keepScreenshot(app, name: "393-simulator-same-route-transport-retired")
        let transientNotice = app.descendants(matching: .any).matching(identifier: "in-app-notice-card").firstMatch
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: transientNotice
        )], timeout: 20), .completed)
        keepScreenshot(app, name: "393-simulator-retained-after-transient-notice")
        XCTAssertTrue(app.buttons["Waiting for connection"].isHittable,
                      "the mounted chat must keep its visible inline lifecycle reason after the transient notice expires")
        XCTAssertTrue(sameRouteReply.isHittable, "recovery must not cover the retained reply")
        try setProxyMode(fixture, mode: "pass")
        try setProxyMode(fixture, mode: "hold-open")
        // Foreground admission owns an immediate attempt; the response barrier
        // below proves that the new subscription has not finished installing.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(waitForBackground(app, timeout: 60))
        app.activate()
        XCTAssertTrue(waitForForeground(app, timeout: 90))
        try setProxyMode(fixture, mode: "await-intercepted")
        keepScreenshot(app, name: "393-simulator-same-route-reopen-held")
        XCTAssertTrue(sameRouteReply.exists,
                      "subscription replacement discarded the same-session transcript")
        XCTAssertFalse(app.otherElements["Opening conversation"].exists,
                       "a retained conversation must not be hidden by the full opening surface")
        XCTAssertEqual(sameRouteReply.frame.minY, replyFrameBeforeLoss.minY, accuracy: 3,
                       "the pinned transcript moved while its replacement open was held")
        XCTAssertEqual(composer.value as? String, unsentDraft,
                       "the replacement open must preserve the full draft")
        XCTAssertTrue(app.keyboards.firstMatch.exists,
                      "the held replacement open must preserve the active composer keyboard")
        XCTAssertEqual(composer.frame.minY, composerFrameBeforeLoss.minY, accuracy: 3)
        XCTAssertEqual(composer.frame.height, composerFrameBeforeLoss.height, accuracy: 3)
        // Type without refocusing: a visible keyboard alone does not prove the
        // same draft still owns its responder/caret after replacement.
        app.typeText(" Still editing.")
        unsentDraft += " Still editing."
        XCTAssertEqual(composer.value as? String, unsentDraft)
        try setProxyMode(fixture, mode: "pass")
        XCTAssertTrue(sameRouteReply.waitForExistence(timeout: 60))
        XCTAssertTrue(waitForEnabled(send, timeout: 60), "replacement authority did not become ready")

        // A definitive answer from the real Gateway is not transport loss. The
        // proxy asks for an absent session, then forwards the actual rejection.
        try setProxyMode(fixture, mode: "reject-open")
        try setProxyMode(fixture, mode: "close", code: 1012)
        try setProxyMode(fixture, mode: "await-intercepted")
        XCTAssertTrue(app.buttons["Conversation unavailable"].waitForExistence(timeout: 30),
                      "a Gateway rejection must leave a persistent inline failure over retained rows")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: transientNotice
        )], timeout: 30), .completed,
                       "the transient catch-up notice must retire before qualifying persistent failure")
        keepScreenshot(app, name: "393-simulator-persistent-gateway-failure")
        XCTAssertTrue(app.buttons["Conversation unavailable"].isHittable)
        XCTAssertTrue(sameRouteReply.isHittable, "Gateway failure covered the retained transcript")
        XCTAssertEqual(composer.value as? String, unsentDraft)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertFalse(app.otherElements["Opening conversation"].exists)
        try setProxyMode(fixture, mode: "pass")
        XCTAssertTrue(waitForHittable(app.buttons["Retry"], timeout: 10))
        app.buttons["Retry"].tap()
        XCTAssertTrue(waitForEnabled(send, timeout: 60), "explicit retry did not restore command authority")

        // A real reader detaches from the tail; this is not a short transcript
        // that happens to fit in the viewport. Scrolling intentionally dismisses
        // the keyboard, separately from the pinned keyboard-preservation checks.
        let transcriptScroll = app.scrollViews.containing(
            NSPredicate(format: "label CONTAINS %@", "real Gateway round trip")
        ).firstMatch
        XCTAssertTrue(transcriptScroll.exists)
        // The separate status-bar scroll owner is a 1-point UIScrollView; target
        // the actual conversation and keep the gesture above the keyboard.
        let readerStart = transcriptScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let readerEnd = transcriptScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.48))
        readerStart.press(forDuration: 0.1, thenDragTo: readerEnd)
        readerStart.press(forDuration: 0.1, thenDragTo: readerEnd)
        keepScreenshot(app, name: "393-simulator-reader-detaches")
        XCTAssertTrue(app.buttons["Catch up"].waitForExistence(timeout: 10),
                      "the reader did not leave the pinned tail: \(app.debugDescription)")
        XCTAssertTrue(sent.isHittable)
        let anchorFrame = sent.frame
        try setProxyMode(fixture, mode: "blackhole")
        XCTAssertTrue(app.buttons["Waiting for connection"].waitForExistence(timeout: 60))
        XCTAssertEqual(sent.frame.minY, anchorFrame.minY, accuracy: 3,
                       "transport retirement moved the anchored reader")
        try setProxyMode(fixture, mode: "pass")
        try setProxyMode(fixture, mode: "hold-open")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(waitForBackground(app, timeout: 60))
        app.activate()
        XCTAssertTrue(waitForForeground(app, timeout: 90))
        try setProxyMode(fixture, mode: "await-intercepted")
        keepScreenshot(app, name: "393-simulator-anchored-replacement-held")
        XCTAssertTrue(sent.isHittable)
        XCTAssertEqual(sent.frame.minY, anchorFrame.minY, accuracy: 3,
                       "replacement open repinned the anchored reader")
        XCTAssertEqual(composer.value as? String, unsentDraft)
        XCTAssertFalse(app.otherElements["Opening conversation"].exists)
        // Retire an in-flight replacement before its held answer can install.
        // The replacement transport must win without publishing a stale failure.
        try setProxyMode(fixture, mode: "replace-held-open")
        try setProxyMode(fixture, mode: "await-intercepted")
        keepScreenshot(app, name: "393-simulator-replacement-transport-open-held")
        XCTAssertTrue(sent.isHittable)
        XCTAssertEqual(sent.frame.minY, anchorFrame.minY, accuracy: 3)
        XCTAssertFalse(app.buttons["Conversation unavailable"].exists)
        XCTAssertFalse(app.otherElements["Opening conversation"].exists)
        try setProxyMode(fixture, mode: "pass")
        XCTAssertTrue(waitForEnabled(send, timeout: 60))
        XCTAssertEqual(sent.frame.minY, anchorFrame.minY, accuracy: 3)
        XCTAssertEqual(composer.value as? String, unsentDraft)
        XCTAssertFalse(app.staticTexts["Conversation unavailable"].exists)
        XCTAssertTrue(app.buttons["Catch up"].exists)
        app.buttons["Catch up"].tap()
        XCTAssertTrue(waitForHittable(sameRouteReply, timeout: 30))

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

        // Reopen the same retained session from the dashboard after the real
        // transport is gone. This exercises a fresh ChatView opening while the
        // Gateway lifecycle is disconnected, not the already-open blackhole
        // control (which is covered separately and passes unchanged main).
        app.buttons["Back"].tap()
        let sessionRow = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "session-row-")
        ).firstMatch
        XCTAssertTrue(waitForHittable(sessionRow, timeout: 60), app.debugDescription)
        try setProxyMode(fixture, mode: "blackhole")
        defer { try? setProxyMode(fixture, mode: "pass") }
        // Open immediately, before the liveness deadline retires the socket. The
        // opening's actual Gateway request is then interrupted by the path loss.
        sessionRow.tap()
        let opening = app.otherElements["Opening conversation"]
        XCTAssertTrue(opening.waitForExistence(timeout: 15),
                      "the session row did not mount a fresh opening: \(app.debugDescription)")
        XCTAssertTrue(
            app.staticTexts["Gateway connection unavailable"].waitForExistence(timeout: 60),
            "the real connection loss was not surfaced: \(app.debugDescription)"
        )
        let retry = app.buttons["Retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 60),
                      "the interrupted open did not expose recovery: \(app.debugDescription)")
        keepScreenshot(app, name: "393-simulator-interrupted-open-before-retry")
        retry.tap()
        Thread.sleep(forTimeInterval: 3)
        keepScreenshot(app, name: "393-simulator-disconnected-retry")
        XCTAssertFalse(opening.exists,
                       "Retry while disconnected must not replace recovery with an opening spinner")
        XCTAssertTrue(app.staticTexts["Waiting for connection"].exists)
        // Navigation intentionally retired the old snapshot; this new route
        // cannot claim a retained transcript until it synchronizes.
        try setProxyMode(fixture, mode: "pass")
        let retainedReply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", replyCompletion)).firstMatch
        XCTAssertTrue(retainedReply.waitForExistence(timeout: 60),
                      "the waiting route did not resume without another tap: \(app.debugDescription)")
        XCTAssertFalse(app.staticTexts["Waiting for connection"].exists)
        keepScreenshot(app, name: "393-simulator-reconnected-without-retry")
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

    /// Settings surfaces serve the schema's keys (docs/settings-model.md 7.7). For
    /// each surface, every key whose layers include one the surface's target has
    /// is a reachable row with a layer badge and a value; a key with none of them
    /// has no row. A layer the surface does not own offers its "Edit at …" path,
    /// and an accepted edit reads back after reopening, from the Gateway's
    /// resolution. Expectations come from the fixture Gateway's own schema
    /// inventory (`TRON_E2E_SETTINGS_INVENTORY`), never from a Swift key list.
    @MainActor
    func testSettingsSurfacesServeEveryKeyAndEditAtItsLayer() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let schema = try SettingsSchemaInventory.fromEnvironment()
        let app = launchApp()
        defer { app.terminate() }
        open(fixture.invitationLink())
        completeFirstRunSetup(app, inWorkspace: fixture.workspace)
        XCTAssertTrue(waitForHittable(app.buttons["dashboard.menu"], timeout: 90),
                      "the invitation link and setup did not reach the dashboard: \(app.debugDescription)")
        createSession(app, inWorkspace: fixture.workspace)
        var coverage: [String: SurfaceCoverage] = [:]

        // Manage Session: the Chat, Project and Mac layers of this chat.
        let chatGear = app.navigationBars.buttons["Manage Session"]
        XCTAssertTrue(chatGear.waitForExistence(timeout: 60), app.debugDescription)
        chatGear.tap()
        XCTAssertTrue(app.staticTexts["Manage Session"].waitForExistence(timeout: 30), app.debugDescription)
        expandAllSettings(app)
        coverage["manage-session"] = assertSettingsSurface(app, name: "manage-session",
            layers: ["chat", "project", "mac"], schema: schema)
        let chatLayerRetry = toggleSetting(app, key: "run.retry.enabled", expectingBadge: schema.label(for: "chat"))
        XCTAssertNotEqual(chatLayerRetry.before, chatLayerRetry.after, "the Chat-layer edit was not accepted")
        // A Mac-only key on this surface names its own editor, which opens Settings.
        let macEditor = hittableElement(app, identifier: settingRowToken("setup.installTelemetry") + "-edit-layer")
        XCTAssertNotNil(macEditor, "setup.installTelemetry is Mac-only and must offer Edit at Mac here")
        macEditor?.tap()
        // The Mac layer's editor is Settings itself.
        let layerSheetDone = app.buttons["settings-done"]
        XCTAssertTrue(layerSheetDone.waitForExistence(timeout: 15), "Edit at Mac must present the Mac layer's Settings sheet: \(app.debugDescription)")
        layerSheetDone.tap()
        XCTAssertTrue(waitForNonExistence(layerSheetDone, timeout: 15), "the layer editor must dismiss")
        XCTAssertTrue(app.staticTexts["Manage Session"].waitForExistence(timeout: 10), "dismissing Settings must return to Manage Session")
        // Reopen: the Chat-layer value and its badge are read from the Gateway again.
        dismissTopSheet(app)
        XCTAssertTrue(waitForNonExistence(app.staticTexts["Manage Session"], timeout: 15))
        chatGear.tap()
        XCTAssertTrue(app.staticTexts["Manage Session"].waitForExistence(timeout: 30), app.debugDescription)
        expandAllSettings(app)
        let reopenedRetry = settingRow(app, key: "run.retry.enabled")
        XCTAssertTrue(waitForBadge(reopenedRetry, schema.label(for: "chat"), timeout: 30),
                      "the reopened Manage Session must show the Chat badge: \(reopenedRetry.debugDescription)")
        XCTAssertEqual(switchValue(reopenedRetry), chatLayerRetry.after, "the reopened Chat value is not the accepted value")
        keepScreenshot(app, name: "settings-surface-manage-session-chat-edit")
        dismissTopSheet(app)
        XCTAssertTrue(waitForNonExistence(app.staticTexts["Manage Session"], timeout: 15))

        // Settings (Mac layer) from the dashboard: one Mac key edits and reads back.
        app.buttons["Back"].tap()
        let menu = app.buttons["dashboard.menu"]
        XCTAssertTrue(waitForHittable(menu, timeout: 60), app.debugDescription)
        menu.tap()
        let settingsAction = app.buttons["Settings"]
        XCTAssertTrue(settingsAction.waitForExistence(timeout: 30), app.debugDescription)
        settingsAction.tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 30), app.debugDescription)
        expandAllSettings(app)
        coverage["settings"] = assertSettingsSurface(app, name: "settings", layers: ["mac"], schema: schema)
        let macEdit = toggleSetting(app, key: "setup.installTelemetry", expectingBadge: schema.label(for: "mac"))
        XCTAssertNotEqual(macEdit.before, macEdit.after, "the Mac-layer edit was not accepted")
        dismissTopSheet(app)
        XCTAssertTrue(waitForNonExistence(app.staticTexts["Settings"], timeout: 15))
        menu.tap()
        settingsAction.tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 30), app.debugDescription)
        expandAllSettings(app)
        let reopenedTelemetry = settingRow(app, key: "setup.installTelemetry")
        XCTAssertTrue(waitForBadge(reopenedTelemetry, schema.label(for: "mac"), timeout: 30),
                      "the reopened Settings must show the Mac badge: \(reopenedTelemetry.debugDescription)")
        XCTAssertEqual(switchValue(reopenedTelemetry), macEdit.after, "the reopened Mac value is not the accepted value")
        keepScreenshot(app, name: "settings-surface-settings-mac-edit")
        dismissTopSheet(app)
        XCTAssertTrue(waitForNonExistence(app.staticTexts["Settings"], timeout: 15))

        // An outside edit replaces the value Tron wrote (settings-model.md 5.6): the
        // reopened row says so and Apply again writes Tron's value back.
        try editMacSettingsOutsideTron(fixture.agentDirectory) { document in
            document["enableInstallTelemetry"] = macEdit.before == "1"
        }
        menu.tap()
        settingsAction.tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 30), app.debugDescription)
        expandAllSettings(app)
        let outsideRow = settingRow(app, key: "setup.installTelemetry")
        // The badge's accessible label carries its detail ("Changed outside Tron, Mac: On → Off").
        XCTAssertTrue(waitUntil(timeout: 30) { self.badgeLabels(outsideRow).contains { $0.hasPrefix("Changed outside Tron") } },
                      "an outside edit of Tron's value must be shown: \(badgeLabels(outsideRow))")
        XCTAssertEqual(switchValue(outsideRow), macEdit.before, "the live value must follow the edited store")
        let applyAgain = hittableElement(app, identifier: settingRowToken("setup.installTelemetry") + "-applyAgain")
        XCTAssertNotNil(applyAgain, "the outside change of Tron's value must offer Apply again: \(app.debugDescription)")
        keepScreenshot(app, name: "settings-surface-outside-change-apply-again")
        applyAgain?.tap()
        XCTAssertTrue(waitUntil(timeout: 60) {
            self.switchValue(outsideRow) == macEdit.after && !self.badgeLabels(outsideRow).contains { $0.hasPrefix("Changed outside Tron") }
        }, "Apply again must restore Tron's value and clear the outside mark: \(badgeLabels(outsideRow))")
        dismissTopSheet(app)
        XCTAssertTrue(waitForNonExistence(app.staticTexts["Settings"], timeout: 15))

        // Project card from the dashboard's workspace header: the Project layer
        // and the Mac key that qualifies by this project.
        let folderName = fixture.workspace.split(separator: "/").last.map(String.init) ?? fixture.workspace
        let header = app.buttons[folderName].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 30), "the dashboard has no header for \(folderName): \(app.debugDescription)")
        openProjectCard(app, header: header)
        expandAllSettings(app)
        coverage["project"] = assertSettingsSurface(app, name: "project", layers: ["project", "mac"], schema: schema)
        let projectEdit = toggleSetting(app, key: "context.compaction.enabled", expectingBadge: schema.label(for: "project"))
        XCTAssertNotEqual(projectEdit.before, projectEdit.after, "the Project-layer edit was not accepted")
        // The project's trust decision is a Mac key qualified by this project: its
        // row offers Edit at Mac, which opens the Mac layer's Settings.
        let trustEditor = revealedElement(app, where: NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
            settingRowToken("permissions.projectTrust"), "-edit-layer"))
        XCTAssertNotNil(trustEditor, "the project trust row must offer Edit at Mac on the Project card")
        trustEditor?.tap()
        let trustSheetDone = app.buttons["settings-done"]
        XCTAssertTrue(trustSheetDone.waitForExistence(timeout: 15), "Edit at Mac on the Project card must open Settings: \(app.debugDescription)")
        trustSheetDone.tap()
        XCTAssertTrue(waitForNonExistence(trustSheetDone, timeout: 15), "the layer editor must dismiss")
        XCTAssertTrue(app.staticTexts["Project settings"].waitForExistence(timeout: 10))
        dismissTopSheet(app)
        XCTAssertTrue(waitForNonExistence(app.staticTexts["Project settings"], timeout: 15))
        openProjectCard(app, header: header)
        expandAllSettings(app)
        let reopenedCompaction = settingRow(app, key: "context.compaction.enabled")
        XCTAssertTrue(waitForBadge(reopenedCompaction, schema.label(for: "project"), timeout: 30),
                      "the reopened Project card must show the Project badge: \(reopenedCompaction.debugDescription)")
        XCTAssertEqual(switchValue(reopenedCompaction), projectEdit.after, "the reopened Project value is not the accepted value")
        keepScreenshot(app, name: "settings-surface-project-layer-edit")
        dismissTopSheet(app)

        let attachment = XCTAttachment(string: coverageReport(coverage, schema: schema))
        attachment.name = "settings-surface-coverage.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Settings surface helpers

    /// A hand edit of the fixture's Mac `settings.json`, as an editor would make
    /// it: write a sibling file, then rename it over the store.
    private func editMacSettingsOutsideTron(_ agentDirectory: String?, _ edit: (inout [String: Any]) -> Void) throws {
        let directory = try XCTUnwrap(agentDirectory, "run through scripts/ios-gateway-e2e-test run-ui to name the fixture's agent directory")
        let store = URL(fileURLWithPath: directory).appendingPathComponent("settings.json")
        var document = (try JSONSerialization.jsonObject(with: Data(contentsOf: store)) as? [String: Any]) ?? [:]
        edit(&document)
        let staged = store.deletingLastPathComponent().appendingPathComponent("settings.json.outside-edit")
        try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted]).write(to: staged)
        _ = try FileManager.default.replaceItemAt(store, withItemAt: staged)
    }

    /// What one surface showed for the schema's keys, attached as the journey's coverage report.
    private struct SurfaceCoverage {
        var served = 0
        var rowsPresent = 0
        var optionalAbsent = 0
        var notServed = 0
        var notServedAbsent = 0
        var layerBadgeChecked = 0
        var valueChecked = 0
    }

    /// Every served key of a surface has a row with a value and a source badge
    /// its layers allow; a key the surface's target does not serve has no row.
    /// A key qualified by a fixed key (a floor instance) is served by the Mac
    /// target alone (`settings-resolver.ts` `instances`), and a key qualified by
    /// project has an instance only when a trust decision exists on the Mac target.
    @MainActor
    private func assertSettingsSurface(_ app: XCUIApplication, name: String, layers: Set<String>,
                                       schema: SettingsSchemaInventory) -> SurfaceCoverage {
        var coverage = SurfaceCoverage()
        let isMacTarget = layers == ["mac"]
        let allLayerLabels = Set(schema.layerLabels.values)
        for key in schema.keys {
            let rows = settingRows(app, key: key.id)
            let served = !key.layers.isDisjoint(with: layers) && (key.qualifier != "key" || isMacTarget)
            guard served else {
                coverage.notServed += 1
                XCTAssertEqual(rows.count, 0, "\(name) must not show \(key.id): it is not served on this surface")
                if rows.count == 0 { coverage.notServedAbsent += 1 }
                continue
            }
            coverage.served += 1
            guard rows.count > 0 else {
                XCTAssertTrue(key.qualifier == "project" && isMacTarget, "\(name) serves \(key.id) but shows no row")
                coverage.optionalAbsent += 1
                continue
            }
            coverage.rowsPresent += 1
            let labels = badgeLabels(rows.firstMatch)
            let allowedBadges = Set(key.layers.union(["builtin"]).compactMap { schema.layerLabels[$0] })
            XCTAssertFalse(labels.filter(allowedBadges.contains).isEmpty,
                           "\(name) row \(key.id) shows no source badge among \(allowedBadges.sorted()): \(labels)")
            coverage.layerBadgeChecked += 1
            // A switch's value is part of its button's label, so the value is read from every descendant.
            let row = rows.firstMatch
            let described = row.descendants(matching: .any).allElementsBoundByIndex.map { $0.label }
                + row.switches.allElementsBoundByIndex.compactMap { $0.value as? String }
            XCTAssertTrue(described.contains { !$0.isEmpty && $0 != key.label && !allLayerLabels.contains($0) },
                          "\(name) row \(key.id) shows no value: \(described)")
            coverage.valueChecked += 1
        }
        return coverage
    }

    /// Exact row identifiers: the key's own row, and each qualified instance
    /// (`<token>_<qualifiers>`). Child identifiers such as `-note` never match.
    @MainActor
    private func settingRows(_ app: XCUIApplication, key: String) -> XCUIElementQuery {
        let token = settingRowToken(key)
        return app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ OR identifier BEGINSWITH %@", token, token + "_"))
    }

    @MainActor
    private func settingRow(_ app: XCUIApplication, key: String) -> XCUIElement {
        app.descendants(matching: .any)[settingRowToken(key)]
    }

    /// Reveals the first on-screen element matching the predicate in the top-most
    /// presentation. Covered presentations are not hittable, so a nested sheet's
    /// rows never resolve to the sheet beneath it.
    @MainActor
    private func revealedElement(_ app: XCUIApplication, where predicate: NSPredicate, timeout: TimeInterval = 20) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        var swipes = 0
        repeat {
            let candidates = app.descendants(matching: .any).matching(predicate)
            for index in 0..<min(candidates.count, 16) where candidates.element(boundBy: index).isHittable {
                return candidates.element(boundBy: index)
            }
            if swipes < 30 {
                app.swipeUp()
                swipes += 1
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return nil
    }

    @MainActor
    private func hittableElement(_ app: XCUIApplication, identifier: String, timeout: TimeInterval = 20) -> XCUIElement? {
        revealedElement(app, where: NSPredicate(format: "identifier == %@", identifier), timeout: timeout)
    }

    @MainActor
    private func hittableStaticText(_ app: XCUIApplication, _ text: String) -> XCUIElement? {
        revealedElement(app, where: NSPredicate(format: "label == %@ AND elementType == %d", text, XCUIElement.ElementType.staticText.rawValue), timeout: 6)
    }

    @MainActor
    private func expandAllSettings(_ app: XCUIApplication) {
        guard let all = hittableElement(app, identifier: "settings-renderer-all", timeout: 30) else {
            XCTFail("All settings is not reachable: \(app.debugDescription)")
            return
        }
        // The control's row Button spans the whole container; its switch is not
        // a separate descendant of the identified surface.
        all.tap()
    }

    @MainActor
    private func dismissTopSheet(_ app: XCUIApplication) {
        guard let done = revealedElement(app, where: NSPredicate(format: "label == %@", "Done"), timeout: 10) else {
            XCTFail("no hittable Done control to dismiss the presented sheet: \(app.debugDescription)")
            return
        }
        done.tap()
    }

    /// The Project card, from the dashboard's workspace header context menu.
    @MainActor
    private func openProjectCard(_ app: XCUIApplication, header: XCUIElement) {
        header.press(forDuration: 1.2)
        let projectSettings = app.buttons["Project settings"]
        XCTAssertTrue(projectSettings.waitForExistence(timeout: 15), app.debugDescription)
        projectSettings.tap()
        XCTAssertTrue(app.staticTexts["Project settings"].waitForExistence(timeout: 30), app.debugDescription)
    }

    /// A switch row's value, read from the row's own switch.
    private func switchValue(_ row: XCUIElement) -> String? {
        row.switches.firstMatch.value.map { String(describing: $0) }
    }

    private func badgeLabels(_ row: XCUIElement) -> [String] {
        row.staticTexts.allElementsBoundByIndex.map { $0.label }
    }

    /// Toggles one row's switch through the shared control and waits for the
    /// Gateway's accepted state: the value flips and the badge names the layer.
    @MainActor
    private func toggleSetting(_ app: XCUIApplication, key: String, expectingBadge badge: String) -> (before: String?, after: String?) {
        let row = settingRow(app, key: key)
        XCTAssertTrue(row.waitForExistence(timeout: 15), "\(key) has no row: \(app.debugDescription)")
        let toggle = row.switches.firstMatch
        var swipes = 0
        while !toggle.isHittable && swipes < 12 {
            app.swipeUp()
            swipes += 1
        }
        let before = switchValue(row)
        toggle.tap()
        XCTAssertTrue(waitUntil(timeout: 60) {
            self.switchValue(row) != before && self.badgeLabels(row).contains(badge)
        }, "the accepted \(key) change did not show the \(badge) badge: \(badgeLabels(row))")
        return (before, switchValue(row))
    }

    @MainActor
    private func waitForBadge(_ row: XCUIElement, _ badge: String, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) { self.badgeLabels(row).contains(badge) }
    }

    @MainActor
    private func waitForNonExistence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) { !element.exists }
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return condition()
    }

    private func coverageReport(_ coverage: [String: SurfaceCoverage], schema: SettingsSchemaInventory) -> String {
        let surfaces = coverage.mapValues { surface -> [String: Int] in
            ["served": surface.served, "rowsPresent": surface.rowsPresent, "optionalAbsent": surface.optionalAbsent,
             "notServed": surface.notServed, "notServedAbsent": surface.notServedAbsent,
             "layerBadgeChecked": surface.layerBadgeChecked, "valueChecked": surface.valueChecked]
        }
        let report: [String: Any] = ["schema": "tron.ios-settings-surface-coverage.v1", "schemaKeys": schema.keys.count,
                                     "surfaces": surfaces]
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])) ?? Data()
        return String(decoding: data, as: UTF8.self)
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
    private func setProxyMode(_ fixture: RealGatewayUIFixture, mode: String, code: Int? = nil) throws {
        let token = try XCTUnwrap(ProcessInfo.processInfo.environment["TRON_E2E_PROXY_TOKEN"])
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://\(fixture.host):\(fixture.port)/_fixture/control")))
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "x-tron-fixture-token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var control: [String: Any] = ["mode": mode]
        if let code { control["code"] = code }
        request.httpBody = try JSONSerialization.data(withJSONObject: control)
        let completed = expectation(description: "fixture proxy \(mode)")
        URLSession.shared.dataTask(with: request) { _, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            completed.fulfill()
        }.resume()
        wait(for: [completed], timeout: 15)
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
/// this runner: the fixture's port and one-time code. The journey drives the
/// app's own state itself, and the harness only returns the app to its unpaired
/// state when the run ends.
private struct RealGatewayUIFixture {
    let host = "127.0.0.1"
    let port: Int
    let code: String
    let workspace: String
    /// The fixture Gateway's agent directory on this Mac (its Mac settings store).
    var agentDirectory: String? = nil

    static func fromEnvironment() throws -> RealGatewayUIFixture {
        let environment = ProcessInfo.processInfo.environment
        guard let portText = environment["TRON_E2E_PORT"], let port = Int(portText),
              let code = environment["TRON_E2E_CODE"],
              let workspace = environment["TRON_E2E_WORKSPACE"] else {
            throw XCTSkip("Run through scripts/ios-gateway-e2e-test run-ui to provide the real Gateway fixture.")
        }
        return RealGatewayUIFixture(port: port, code: code, workspace: workspace, agentDirectory: environment["TRON_E2E_AGENT_DIR"])
    }

    /// The production invitation link, addressed at the fixture's fault proxy so
    /// every byte of the pairing and of the session crosses it.
    func invitationLink(code: String? = nil) -> String {
        "tron://pair?host=\(host)&port=\(port)&code=\(code ?? self.code)"
    }
}

/// The fixture Gateway's settings schema, dumped by the E2E harness from its own
/// built `settings-schema.ts` (`TRON_E2E_SETTINGS_INVENTORY`): one row per schema
/// key with the layers it allows, its label and its qualifier, plus the Gateway's
/// layer labels. Expectations come from it, never from a Swift copy of the keys.
private struct SettingsSchemaInventory {
    struct Key {
        let id: String
        let label: String
        let layers: Set<String>
        let qualifier: String?
    }

    let layerLabels: [String: String]
    let keys: [Key]

    func label(for layer: String) -> String { layerLabels[layer] ?? layer }

    static func fromEnvironment() throws -> SettingsSchemaInventory {
        guard let text = ProcessInfo.processInfo.environment["TRON_E2E_SETTINGS_INVENTORY"] else {
            throw XCTSkip("Run through scripts/ios-gateway-e2e-test run-ui to provide the fixture's settings schema inventory.")
        }
        guard let document = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let labels = document["layerLabels"] as? [String: String],
              let rows = document["keys"] as? [[String: Any]], !rows.isEmpty else {
            throw SettingsInventoryError.malformed
        }
        let keys = try rows.map { row -> Key in
            guard let id = row["id"] as? String, let label = row["label"] as? String,
                  let layers = row["layers"] as? [String] else { throw SettingsInventoryError.malformed }
            return Key(id: id, label: label, layers: Set(layers), qualifier: row["qualifier"] as? String)
        }
        return SettingsSchemaInventory(layerLabels: labels, keys: keys)
    }
}

private enum SettingsInventoryError: Error { case malformed }

/// The accessibility identifier of a settings row, as `SettingsRendererRow` names it.
private func settingRowToken(_ key: String) -> String {
    "settings-row-" + String(key.unicodeScalars.map { scalar in
        CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" ? Character(scalar) : "_"
    })
}
