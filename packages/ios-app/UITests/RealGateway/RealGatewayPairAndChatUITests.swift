import Foundation
import UIKit
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

    /// #931: real home.status bytes cross the socket and the production DTO into
    /// the pinned row, even before Home is designated. This fixture starts no
    /// workers; the actual Mac's pressure is intentionally not forced or loaded.
    /// Hosted Home journeys separately distinguish all three pressure levels.
    @MainActor
    func testHomeStatusShowsHostPressureAndWorkers() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let app = launchApp()
        defer { app.terminate() }
        open(fixture.invitationLink())
        completeFirstRunSetup(app, inWorkspace: fixture.workspace)
        let home = app.buttons["home-pinned-row"]
        XCTAssertTrue(home.waitForExistence(timeout: 60), app.debugDescription)
        let published = NSPredicate(format: "label CONTAINS '0 workers running'")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: published, object: home)], timeout: 30), .completed)
        XCTAssertTrue(["normal", "elevated", "critical"].contains { home.label.contains("Host \($0)") }, home.label)
        XCTAssertFalse(home.label.lowercased().contains("queued"), home.label)
        keepScreenshot(app, name: "931-real-gateway-home-host-status")
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
        let waitingStatus = recoveryStatus(app, "Waiting for connection")
        XCTAssertTrue(waitingStatus.isHittable,
                      "the mounted chat must keep its visible lifecycle reason after the transient notice expires")
        assertRecoveryInChrome(app, status: waitingStatus)
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
        XCTAssertFalse(waitingStatus.exists, "the replacement connection left its recovery status behind")

        // #878: a background transition intentionally retires the transport, so
        // every foreground reconnects. An ordinary reconnect is not an outage and
        // must stay quiet for the whole foreground, not flash recovery chrome.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(waitForBackground(app, timeout: 60))
        app.activate()
        XCTAssertTrue(waitForForeground(app, timeout: 90))
        let quietForegroundUntil = Date().addingTimeInterval(4)
        while Date() < quietForegroundUntil {
            if waitingStatus.exists {
                keepScreenshot(app, name: "878-simulator-fast-foreground-flashed-recovery")
                XCTFail("an ordinary foreground reconnect showed connection recovery")
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(waitForEnabled(send, timeout: 60), "the ordinary foreground did not reconnect")
        keepScreenshot(app, name: "878-simulator-fast-foreground-quiet")
        XCTAssertTrue(sameRouteReply.isHittable)
        XCTAssertEqual(composer.value as? String, unsentDraft)
        XCTAssertTrue(app.keyboards.firstMatch.exists,
                      "an ordinary foreground must preserve the active composer keyboard")

        // A foreground reconnect whose handshake is still in flight stays quiet
        // through the app's recovery grace, then names the delay honestly in
        // the route chrome without covering rows or disturbing the draft.
        let replyFrameBeforeForeground = sameRouteReply.frame
        try setProxyMode(fixture, mode: "hold-hello")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(waitForBackground(app, timeout: 60))
        let activationRequestedAt = Date()
        app.activate()
        XCTAssertTrue(waitForForeground(app, timeout: 90))
        // The scene became active no earlier than the request, so a status seen
        // inside this window predates the app's two-second recovery grace.
        // Activation normally returns in about one second; a slower runner
        // records the window rather than asserting against a legitimate status.
        let insideGrace = Date().timeIntervalSince(activationRequestedAt)
        let shownInsideGrace = waitingStatus.exists
        keepScreenshot(app, name: "878-simulator-foreground-handshake-held")
        let graceWindow = XCTAttachment(string: "checkedAfter=\(insideGrace)s shown=\(shownInsideGrace)")
        graceWindow.name = "878-foreground-grace-window"
        graceWindow.lifetime = .keepAlways
        add(graceWindow)
        if insideGrace < 1.8 {
            XCTAssertFalse(shownInsideGrace,
                           "recovery appeared \(insideGrace)s into an ordinary foreground reconnect")
        }
        try setProxyMode(fixture, mode: "await-intercepted")
        XCTAssertTrue(waitingStatus.waitForExistence(timeout: 30),
                      "a held foreground reconnect never named the delay: \(app.debugDescription)")
        let statusAppearedAfter = Date().timeIntervalSince(activationRequestedAt)
        XCTAssertGreaterThanOrEqual(statusAppearedAfter, 2,
                                    "recovery appeared before the reconnect outlived the recovery grace")
        keepScreenshot(app, name: "878-simulator-delayed-foreground-status")
        // The app-scoped recovery card arrives with the same grace and briefly
        // covers the bar; the persistent status must remain after it retires.
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: transientNotice
        )], timeout: 20), .completed)
        keepScreenshot(app, name: "878-simulator-delayed-foreground-status-persistent")
        assertRecoveryInChrome(app, status: waitingStatus)
        XCTAssertTrue(sameRouteReply.isHittable, "delayed-connection status covered the retained reply")
        XCTAssertEqual(sameRouteReply.frame.minY, replyFrameBeforeForeground.minY, accuracy: 3,
                       "delayed-connection status moved the pinned transcript")
        XCTAssertEqual(composer.value as? String, unsentDraft)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        try setProxyMode(fixture, mode: "pass")
        XCTAssertTrue(waitForEnabled(send, timeout: 60), "the delayed reconnect did not finish without Retry")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: waitingStatus
        )], timeout: 30), .completed, "a finished reconnect left its recovery status behind")
        XCTAssertEqual(composer.value as? String, unsentDraft)

        // A definitive answer from the real Gateway is not transport loss. The
        // proxy asks for an absent session, then forwards the actual rejection.
        try setProxyMode(fixture, mode: "reject-open")
        try setProxyMode(fixture, mode: "close", code: 1012)
        try setProxyMode(fixture, mode: "await-intercepted")
        let unavailableStatus = recoveryStatus(app, "Conversation unavailable")
        XCTAssertTrue(unavailableStatus.waitForExistence(timeout: 30),
                      "a Gateway rejection must leave a persistent failure beside retained rows")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: transientNotice
        )], timeout: 30), .completed,
                       "the transient catch-up notice must retire before qualifying persistent failure")
        keepScreenshot(app, name: "393-simulator-persistent-gateway-failure")
        XCTAssertTrue(unavailableStatus.isHittable)
        assertRecoveryInChrome(app, status: unavailableStatus)
        XCTAssertTrue(sameRouteReply.isHittable, "Gateway failure covered the retained transcript")
        XCTAssertEqual(composer.value as? String, unsentDraft)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertFalse(app.otherElements["Opening conversation"].exists)
        try setProxyMode(fixture, mode: "pass")
        XCTAssertTrue(waitForHittable(unavailableStatus, timeout: 10))
        unavailableStatus.tap()
        XCTAssertTrue(waitForEnabled(send, timeout: 60), "explicit retry did not restore command authority")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: unavailableStatus
        )], timeout: 30), .completed, "a successful Retry left its failure status behind")

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
        // The prompt is one accessibility element taller than the viewport;
        // XCUI clips its frame to the visible region beneath the bar, and that
        // clipped edge follows the title view while recovery replaces it. The
        // rendered rows are the reader's position, so qualify their pixels too.
        let rowsBeforeLoss = transcriptRows(app)
        try setProxyMode(fixture, mode: "blackhole")
        XCTAssertTrue(waitingStatus.waitForExistence(timeout: 60))
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: transientNotice
        )], timeout: 20), .completed)
        keepScreenshot(app, name: "878-simulator-anchored-reader-persistent-recovery")
        let movedRows = changedPixelFraction(rowsBeforeLoss, transcriptRows(app))
        XCTAssertLessThan(movedRows, 0.01,
                          "transport retirement moved the anchored reader (\(movedRows) of its rows changed)")
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
        XCTAssertFalse(unavailableStatus.exists)
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

        // #878 at accessibility text size: relaunch the same paired app (no
        // reset) and require the persistent status and Retry to stay inside the
        // navigation chrome, reachable, without covering the retained reply.
        app.terminate()
        let largeText = XCUIApplication()
        largeText.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        largeText.launch()
        defer { largeText.terminate() }
        let largeRow = largeText.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "session-row-")
        ).firstMatch
        XCTAssertTrue(waitForHittable(largeRow, timeout: 90), largeText.debugDescription)
        largeRow.tap()
        let largeReply = largeText.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", replyCompletion)).firstMatch
        XCTAssertTrue(largeReply.waitForExistence(timeout: 60), largeText.debugDescription)
        try setProxyMode(fixture, mode: "blackhole")
        let largeStatus = recoveryStatus(largeText, "Waiting for connection")
        XCTAssertTrue(largeStatus.waitForExistence(timeout: 90),
                      "transport loss at accessibility text size showed no recovery: \(largeText.debugDescription)")
        let largeNotice = largeText.descendants(matching: .any).matching(identifier: "in-app-notice-card").firstMatch
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: largeNotice
        )], timeout: 20), .completed)
        keepScreenshot(largeText, name: "878-simulator-accessibility-xxxl-recovery")
        assertRecoveryInChrome(largeText, status: largeStatus)
        XCTAssertEqual(largeStatus.value as? String, "This conversation will resume when the Mac reconnects.",
                       "VoiceOver must receive the full recovery explanation")
        try setProxyMode(fixture, mode: "pass")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: largeStatus
        )], timeout: 90), .completed, "the large-text route did not reconnect on its own")
    }

    /// #935: reopening a running session whose agent waits on `ask_user`
    /// presents the form as soon as the transcript crosses its first ready
    /// frame. Sending the answers must leave that mounted transcript alone: no
    /// second opening attempt, no hidden-then-revealed transcript (the reported
    /// flicker and reload), the same rows, and the newest reply visible at the
    /// tail. A loaded phone can commit the form's cover before the opening
    /// task has drained; the hosted hold argument keeps that tail alive for a
    /// bounded number of frames so the journey always takes that order. The
    /// hosted lifecycle element is a monotonic per-route counter, so a
    /// transient reopen cannot slip between two polls.
    @MainActor
    func testAnsweringAskUserInReopenedRunningSessionKeepsTranscriptMounted() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let firstRun = launchApp()
        open(fixture.invitationLink())
        completeFirstRunSetup(firstRun, inWorkspace: fixture.workspace)
        XCTAssertTrue(
            waitForHittable(firstRun.buttons["dashboard.menu"], timeout: 90),
            "the invitation link and setup did not reach the dashboard: \(firstRun.debugDescription)"
        )
        createSession(firstRun, inWorkspace: fixture.workspace)

        // One completed turn persists the session, so the dashboard lists it
        // while the next turn is still running (a session whose first turn is
        // still running can be missing from the catalog: #944).
        let composer = firstRun.textViews["Message input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 60), firstRun.debugDescription)
        composer.tap()
        composer.typeText("Start the conversation.")
        let send = firstRun.buttons["Send message"]
        XCTAssertTrue(waitForEnabled(send, timeout: 60), "the composer never accepted the prompt: \(firstRun.debugDescription)")
        send.tap()
        XCTAssertTrue(
            firstRun.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", replyCompletion)).firstMatch
                .waitForExistence(timeout: 120),
            "the first turn never completed: \(firstRun.debugDescription)"
        )

        // The fixture model answers this marker with an ask_user call and waits.
        composer.tap()
        composer.typeText("Fixture ask journey: ask me where to deploy.")
        XCTAssertTrue(waitForEnabled(send, timeout: 60), "the composer never accepted the ask prompt: \(firstRun.debugDescription)")
        send.tap()
        XCTAssertTrue(firstRun.buttons["Submit all answers"].waitForExistence(timeout: 90),
                      "the running agent's ask_user form never appeared: \(firstRun.debugDescription)")

        // Leave the question pending and the agent running, then open the
        // running session again from the dashboard of the relaunched,
        // still-paired app. The hold argument applies to this launch only.
        firstRun.terminate()
        let app = launchApp(resettingState: false, additionalArguments: ["--tron-hosted-hold-opening-tail"])
        defer { app.terminate() }
        let sessionRow = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "session-row-")
        ).firstMatch
        XCTAssertTrue(waitForHittable(sessionRow, timeout: 90), app.debugDescription)
        sessionRow.tap()
        let submit = app.buttons["Submit all answers"]
        XCTAssertTrue(waitForHittable(submit, timeout: 90),
                      "the reopened running session did not present its pending form: \(app.debugDescription)")

        let lifecycle = app.descendants(matching: .any)["chat.hosted.presentation-lifecycle"]
        XCTAssertTrue(lifecycle.waitForExistence(timeout: 30), app.debugDescription)
        let openedLifecycle = lifecycle.value as? String
        XCTAssertEqual(openedLifecycle, "attempts=1 ready-exits=0",
                       "the reopened route must reach ready in one opening before the form covers it")
        let prompt = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Fixture ask journey")).firstMatch
        XCTAssertTrue(prompt.exists, "the reopened transcript does not show the prompt: \(app.debugDescription)")
        keepScreenshot(app, name: "935-reopened-running-session-ask-user-form")

        app.buttons["Staging"].tap()
        XCTAssertTrue(waitForEnabled(submit, timeout: 30), "the form never admitted the answer: \(app.debugDescription)")
        submit.tap()
        XCTAssertTrue(waitForAbsence(submit, timeout: 60), "the answered form did not dismiss: \(app.debugDescription)")
        let reply = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Ask journey answered")
        ).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 90),
                      "the agent's reply to the answer never reached the transcript: \(app.debugDescription)")
        // Still pinned to the newest content, without any user scroll.
        XCTAssertTrue(waitForHittable(reply, timeout: 30),
                      "the transcript left the tail after the answer: \(app.debugDescription)")
        keepScreenshot(app, name: "935-answered-ask-user-transcript-mounted")
        XCTAssertEqual(lifecycle.value as? String, openedLifecycle,
                       "answering the form reopened or re-revealed the mounted transcript")
        XCTAssertTrue(prompt.exists, "answering the form dropped the earlier transcript rows")
        XCTAssertFalse(app.otherElements["Opening conversation"].exists)
    }

    /// The Mac replacement (#984) as Connections shows it from the real Gateway:
    /// the Replace Mac App row follows a running journal, its progress sheet
    /// lists every step and updates live as the orchestrator writes, then shows
    /// the settled result. The journal is written where the Gateway reads it,
    /// beside the fixture's Tron home, exactly as the Mac-side orchestrator does.
    @MainActor
    func testMacReplacementRowAndProgressFollowTheJournal() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        guard let agentDirectory = fixture.agentDirectory else { throw XCTSkip("the harness provides the fixture agent directory") }
        let store = URL(fileURLWithPath: agentDirectory).deletingLastPathComponent().appending(path: ".tron-maintenance/replace")
        let operation = UUID().uuidString.lowercased()
        func writeJournal(state: String, current: String?, done: Int, failed: String? = nil) throws {
            let names = ["preflight", "build", "verify-signature", "drain-workers", "stop-gateway", "swap-app", "start", "verify", "finish"]
            let titles = ["Preflight", "Build signed app", "Verify signature", "Stop running workers", "Stop Gateway", "Swap app",
                          "Start new app", "Verify Gateway", "Finish"]
            let steps: [[String: Any]] = names.enumerated().map { index, name in
                let stepState = index < done ? "done" : name == current ? "running" : "pending"
                var step: [String: Any] = ["name": name, "title": titles[index], "state": stepState]
                if stepState == "done" { step["durationSeconds"] = 2.5; step["detail"] = "\(titles[index]) complete" }
                return step
            }
            let journal: [String: Any] = [
                "schema": 1, "kind": "tron-mac-replace", "id": operation, "path": "full",
                "reason": "Full signed build: the Gateway dependency lock changed", "state": state, "attempt": 1,
                "currentStep": current ?? NSNull(), "steps": steps, "workers": [], "error": NSNull(), "rollback": NSNull(),
                "logPath": store.appending(path: "\(operation)/journal.log").path,
            ]
            let directory = store.appending(path: operation)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: journal).write(to: directory.appending(path: "journal.json"), options: .atomic)
            try JSONSerialization.data(withJSONObject: ["id": operation]).write(to: store.appending(path: "current.json"), options: .atomic)
        }
        try writeJournal(state: "running", current: "build", done: 1)
        defer { try? FileManager.default.removeItem(at: store) }

        let app = launchApp()
        defer { app.terminate() }
        open(fixture.invitationLink())
        completeFirstRunSetup(app, inWorkspace: fixture.workspace)
        XCTAssertTrue(waitForHittable(app.buttons["dashboard.menu"], timeout: 90), app.debugDescription)
        createSession(app, inWorkspace: fixture.workspace)
        let gear = app.navigationBars.buttons["Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 30), app.debugDescription)
        gear.tap()
        let link = app.buttons["settings-link-Connections"]
        for _ in 0..<20 where !link.isHittable { app.swipeDown() }
        link.tap()

        // The row sits in Quick Rebuild with the rebuild rows and follows the running step.
        let progress = app.buttons["Show Mac app replacement progress"]
        for _ in 0..<8 where !progress.isHittable { app.swipeUp() }
        XCTAssertTrue(progress.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Replace Mac App"].exists)
        XCTAssertTrue(app.staticTexts["Step 2 of 9 · Build signed app"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.staticTexts["Replace Mac App"].frame.minX, app.staticTexts["Rebuild Gateway"].frame.minX, accuracy: 1,
                       "the replacement row aligns with the shared rebuild rows")
        keepScreenshot(app, name: "984-connections-row-running")

        progress.tap()
        XCTAssertTrue(app.staticTexts["Step 2 of 9"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Full signed build"].exists)
        keepScreenshot(app, name: "984-progress-running")

        // The orchestrator advances: the open sheet follows without reopening.
        try writeJournal(state: "running", current: "swap-app", done: 5)
        XCTAssertTrue(app.staticTexts["Step 6 of 9"].waitForExistence(timeout: 15), app.debugDescription)
        try writeJournal(state: "succeeded", current: nil, done: 9)
        XCTAssertTrue(app.staticTexts["Replaced"].waitForExistence(timeout: 15), app.debugDescription)
        keepScreenshot(app, name: "984-progress-succeeded")
        dismissTopSheet(app)

        // Settled, the row offers the next replacement's plan and keeps the last journal one tap away.
        let replace = app.buttons["Replace Mac app"]
        XCTAssertTrue(replace.waitForExistence(timeout: 15), app.debugDescription)
        keepScreenshot(app, name: "984-connections-row-settled")
    }

    /// A photo-only message sent while a turn runs is queued as a steer, and
    /// once Pi delivers it the "Steer next" card leaves the composer, also
    /// after the session is reopened (#974). Failure mode: Pi dequeued a
    /// delivered message only when it had text, so the Gateway kept projecting
    /// the delivered photo as queued forever.
    @MainActor
    func testImageOnlySteerLeavesTheQueueOnceDelivered() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let firstRun = launchApp()
        open(fixture.invitationLink())
        completeFirstRunSetup(firstRun, inWorkspace: fixture.workspace)
        XCTAssertTrue(waitForHittable(firstRun.buttons["dashboard.menu"], timeout: 90), firstRun.debugDescription)
        createSession(firstRun, inWorkspace: fixture.workspace)

        // One completed turn persists the session, so the relaunched dashboard
        // lists it (a session created by a held first turn can be missing: #944).
        let composer = firstRun.textViews["Message input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 60), firstRun.debugDescription)
        composer.tap()
        composer.typeText("Start the conversation.")
        let send = firstRun.buttons["Send message"]
        XCTAssertTrue(waitForEnabled(send, timeout: 60), firstRun.debugDescription)
        send.tap()
        XCTAssertTrue(
            firstRun.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", replyCompletion)).firstMatch
                .waitForExistence(timeout: 120),
            "the first turn never completed: \(firstRun.debugDescription)"
        )

        // The fixture model holds this turn until the phone queues a message.
        composer.tap()
        composer.typeText("Fixture steer journey: wait for my photo.")
        XCTAssertTrue(waitForEnabled(send, timeout: 60), firstRun.debugDescription)
        send.tap()
        XCTAssertTrue(firstRun.buttons["Stop Tron"].waitForExistence(timeout: 60),
                      "the held turn never started: \(firstRun.debugDescription)")

        // A photo with no text, pasted into the composer and sent as the default steer.
        UIPasteboard.general.image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        composer.tap()
        let paste = firstRun.menuItems["Paste"]
        for _ in 0..<3 where !paste.exists {
            composer.press(forDuration: 1.0)
            if paste.waitForExistence(timeout: 3) { break }
        }
        XCTAssertTrue(paste.exists, "the composer edit menu offers Paste: \(firstRun.debugDescription)")
        paste.tap()
        XCTAssertTrue(waitForEnabled(send, timeout: 60), "the pasted photo never became sendable: \(firstRun.debugDescription)")
        send.tap()

        // The queued card's delivery detail, "After the current turn · 1 of 1".
        let queuedSteer = firstRun.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "After the current turn")
        ).firstMatch
        XCTAssertTrue(queuedSteer.waitForExistence(timeout: 30),
                      "the photo was not queued as a steer: \(firstRun.debugDescription)")
        keepScreenshot(firstRun, name: "974-image-only-steer-queued")
        let delivered = firstRun.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Steer journey saw the photo")
        ).firstMatch
        XCTAssertTrue(delivered.waitForExistence(timeout: 120),
                      "the model never received the steered photo: \(firstRun.debugDescription)")
        XCTAssertTrue(waitForAbsence(queuedSteer, timeout: 30),
                      "the delivered photo is still shown as a queued steer: \(firstRun.debugDescription)")
        keepScreenshot(firstRun, name: "974-image-only-steer-delivered")

        // Reopen the session in a relaunched, still-paired app: the Gateway's
        // snapshot must not bring the delivered steer back.
        firstRun.terminate()
        let app = launchApp(resettingState: false)
        defer { app.terminate() }
        let sessionRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "session-row-")).firstMatch
        XCTAssertTrue(waitForHittable(sessionRow, timeout: 90), app.debugDescription)
        sessionRow.tap()
        let reopenedReply = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Steer journey saw the photo")
        ).firstMatch
        XCTAssertTrue(reopenedReply.waitForExistence(timeout: 90),
                      "the reopened session does not show the delivered reply: \(app.debugDescription)")
        XCTAssertFalse(
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "After the current turn")).firstMatch
                .waitForExistence(timeout: 5),
            "the reopened session shows the delivered photo as a queued steer: \(app.debugDescription)"
        )
        keepScreenshot(app, name: "974-image-only-steer-reopened")
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

    /// A question `ask_user` asks from inside codemode opens from the running codemode
    /// row and accepts an answer (#929). Failure mode: the row only matched a form to a
    /// top-level `ask_user` row, so tapping the codemode row opened its details and the
    /// question stayed invisible until the run was stopped.
    @MainActor
    func testCodemodeAskUserOpensFromItsToolRowAndAcceptsAnAnswer() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let app = launchApp()
        defer { app.terminate() }
        open(fixture.invitationLink())
        completeFirstRunSetup(app, inWorkspace: fixture.workspace)
        XCTAssertTrue(waitForHittable(app.buttons["dashboard.menu"], timeout: 90), app.debugDescription)
        createSession(app, inWorkspace: fixture.workspace)

        let composer = app.textViews["Message input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 60), app.debugDescription)
        composer.tap()
        // The fixture's provider answers this marker with a codemode call that asks.
        composer.typeText("CODEMODE-ASK-USER-JOURNEY: ask from inside codemode")
        let send = app.buttons["Send message"]
        XCTAssertTrue(waitForEnabled(send, timeout: 60), app.debugDescription)
        send.tap()

        // A question arriving while the chat is open presents itself. Closing it keeps it
        // pending; from then on the codemode row that asked it is the way back to it, as
        // when the maintainer opens a worker whose question is already waiting.
        let submit = app.buttons["Submit all answers"]
        XCTAssertTrue(submit.waitForExistence(timeout: 90), "the codemode question was never presented: \(app.debugDescription)")
        // Swiping the sheet down is the local close (#1123).
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: window.frame.midX, dy: submit.frame.midY))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(waitForNonExistence(submit, timeout: 10), app.debugDescription)
        // The chip reads "Codemode, Invocation" until it runs, then "Builtin Codemode · Codemode, 1 nested, …".
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "Codemode,", "Builtin Codemode")).firstMatch
        XCTAssertTrue(waitForHittable(row, timeout: 30), "the running codemode row is not tappable: \(app.debugDescription)")
        row.tap()
        // The tap reopens the pending question itself, not the row's details sheet.
        XCTAssertTrue(submit.waitForExistence(timeout: 10),
                      "tapping the running codemode row did not reopen its pending question: \(app.debugDescription)")
        // The question text renders as selectable Markdown (#947), so the reopened form is
        // identified by its own option below rather than a static-text lookup.
        XCTAssertTrue(app.buttons["Approve it"].exists, app.debugDescription)
        keepScreenshot(app, name: "929-codemode-ask-user-opened-from-row")
        app.buttons["Approve it"].tap()
        submit.tap()
        let answered = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Codemode question answered")).firstMatch
        XCTAssertTrue(answered.waitForExistence(timeout: 90), "the answer never reached the codemode script: \(app.debugDescription)")
        XCTAssertTrue(answered.label.contains("Approve it"), "the codemode script read another answer: \(answered.label)")
        keepScreenshot(app, name: "929-codemode-ask-user-answered")
    }

    /// X setup through the production Settings parents against a real Gateway
    /// (#366). Failure modes: tapping Authorize X closes the setup sheet before
    /// its consent step appears, so a refused begin's error and an accepted
    /// begin's Open X consent row are both lost with the sheet. The refused
    /// begin is the Gateway's own callback validation and the accepted begin
    /// only persists a pending setup and builds a consent URL locally: no X
    /// endpoint, browser or credential is touched.
    @MainActor
    func testXSetupAuthorizeKeepsSheetForErrorAndConsentStep() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let app = launchApp()
        defer { app.terminate() }
        open(fixture.invitationLink())
        completeFirstRunSetup(app, inWorkspace: fixture.workspace)
        XCTAssertTrue(waitForHittable(app.buttons["dashboard.menu"], timeout: 90), app.debugDescription)
        // The chat's own Settings route, the parent the reported sheet loss used.
        createSession(app, inWorkspace: fixture.workspace)
        let gear = app.navigationBars.buttons["Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 60), app.debugDescription)
        gear.tap()
        guard let services = hittableElement(app, identifier: "settings-link-Connected Services", timeout: 30) else {
            return XCTFail("no Connected Services link: \(app.debugDescription)")
        }
        services.tap()
        let connect = app.buttons["Connect for X"]
        XCTAssertTrue(connect.waitForExistence(timeout: 60), "the fixture Gateway must offer X: \(app.debugDescription)")
        connect.tap()
        let title = app.staticTexts["Set up X"]
        XCTAssertTrue(title.waitForExistence(timeout: 30), app.debugDescription)

        // The shared text row exposes its title on the row, not on the field.
        func field(_ title: String) -> XCUIElement {
            app.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch.textFields.firstMatch
        }
        let client = field("Public client ID")
        let callback = field("Registered callback URL")
        XCTAssertTrue(client.waitForExistence(timeout: 10), app.debugDescription)
        client.tap(); client.typeText("e2e-public-client")
        let refusedCallback = "https://example.test/callback?refused=1"
        callback.tap(); callback.typeText(refusedCallback)
        let authorize = app.buttons["Authorize X"]
        // A user copies the client ID and callback from the X developer console,
        // so the app returns from another app before Authorize X.
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.activate()
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 20), "Safari did not become foreground")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), "Tron did not return to the foreground")
        safari.terminate()
        XCTAssertTrue(title.waitForExistence(timeout: 10), app.debugDescription)
        authorize.tap()

        // The Gateway refuses the query-bearing callback. The refusal must stay
        // on the same sheet with the draft intact, and Authorize X must return.
        let refusal = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "must be HTTPS")).firstMatch
        XCTAssertTrue(refusal.waitForExistence(timeout: 60), "the begin refusal was not shown: \(app.debugDescription)")
        XCTAssertTrue(waitForEnabled(authorize, timeout: 30), app.debugDescription)
        XCTAssertTrue(title.exists && refusal.exists, "the refusal must remain on the setup sheet: \(app.debugDescription)")
        XCTAssertEqual(client.value as? String, "e2e-public-client")
        XCTAssertEqual(callback.value as? String, refusedCallback)
        keepScreenshot(app, name: "366-real-ui-x-begin-refusal-stays")

        // Retry on the same sheet with a valid callback reaches the consent step.
        // Replace the whole draft: caret placement inside a scrolled field is not stable.
        callback.tap()
        callback.typeKey("a", modifierFlags: .command)
        callback.typeText("https://example.test/callback")
        XCTAssertEqual(callback.value as? String, "https://example.test/callback")
        authorize.tap()
        let consent = app.buttons["Open X consent"]
        XCTAssertTrue(consent.waitForExistence(timeout: 60), "Authorize X lost the consent step: \(app.debugDescription)")
        XCTAssertTrue(title.exists, app.debugDescription)
        XCTAssertTrue(app.buttons["Complete setup"].exists, app.debugDescription)
        XCTAssertFalse(refusal.exists, "a successful retry must clear the earlier refusal")
        XCTAssertEqual(client.value as? String, "e2e-public-client")
        keepScreenshot(app, name: "366-real-ui-x-consent-step")
    }

    /// #1073: returning to the app and reconnecting to the Gateway never closes,
    /// re-presents or resets a presented sheet. On iOS 26.4 and later SwiftUI
    /// rebuilds the content of sheets above the chat route when the app returns
    /// from another app, so any state a sheet's content kept for itself (a
    /// terminal's emulator and connection, a typed draft, a nested sheet's
    /// presentation) was lost while the sheet looked as if it stayed open.
    /// Failure modes, each observed from the real interface:
    ///
    /// 1. The session terminal (Manage Session) reconnects from empty: its
    ///    phase passes through "Connecting terminal…" or its rendered output
    ///    is cleared and redrawn after the app returns or the socket reconnects.
    /// 2. Mac Terminal (Settings, over the chat route) reloads: it shows
    ///    "Checking your Mac…" again or its content changes.
    /// 3. A typed draft in a sheet nested in a Settings sheet (MCP Servers ›
    ///    Add Server) is lost, or that sheet closes.
    /// 4. The chat's unsent composer draft does not survive all of it.
    @MainActor
    func testForegroundAndReconnectKeepSheetsAndTheirContent() throws {
        continueAfterFailure = true
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let app = launchApp()
        defer { app.terminate() }
        open(fixture.invitationLink())
        completeFirstRunSetup(app, inWorkspace: fixture.workspace)
        XCTAssertTrue(waitForHittable(app.buttons["dashboard.menu"], timeout: 90), app.debugDescription)
        createSession(app, inWorkspace: fixture.workspace)

        let composer = app.textViews["Message input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 60), app.debugDescription)
        composer.tap()
        let draft = "Unsent draft 1073 survives every sheet round trip"
        composer.typeText(draft)
        XCTAssertEqual(composer.value as? String, draft)

        // 1. The session terminal over Manage Session.
        let ring = app.buttons["session-context-button"]
        XCTAssertTrue(ring.waitForExistence(timeout: 60), app.debugDescription)
        ring.tap()
        let terminalButton = app.buttons["manage-session-terminal"]
        XCTAssertTrue(waitForEnabled(terminalButton, timeout: 60), app.debugDescription)
        terminalButton.tap()
        let terminalTitle = app.descendants(matching: .any)["terminal-sheet-title"].firstMatch
        XCTAssertTrue(waitForValue(terminalTitle, "Connected", timeout: 60), "the session terminal never connected: \(app.debugDescription)")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        XCTAssertTrue(app.buttons["Control modifier"].waitForExistence(timeout: 10), app.debugDescription)
        app.typeText("clear; for i in 1 2 3 4 5 6; do echo SCROLLBACK_1073_LINE_$i; done\n")
        Thread.sleep(forTimeInterval: 2)
        let connectingTerminal = app.staticTexts["Connecting terminal…"]
        let terminalBefore = terminalBody(app)
        keepScreenshot(app, name: "1073-session-terminal-before")

        returnFromAnotherApp(app)
        assertStays(app, presented: terminalTitle, never: connectingTerminal, "the session terminal after returning to the app")
        XCTAssertTrue(waitForValue(terminalTitle, "Connected", timeout: 60), app.debugDescription)
        Thread.sleep(forTimeInterval: 1)
        keepScreenshot(app, name: "1073-session-terminal-after-return")
        let returnedChange = changedPixelFraction(terminalBefore, terminalBody(app))
        XCTAssertLessThan(returnedChange, 0.02, "returning to the app redrew the session terminal (\(returnedChange) of it changed)")

        try forceReconnect(fixture)
        assertStays(app, presented: terminalTitle, never: connectingTerminal, "the session terminal after reconnecting")
        XCTAssertTrue(waitForValue(terminalTitle, "Connected", timeout: 60), app.debugDescription)
        Thread.sleep(forTimeInterval: 1)
        keepScreenshot(app, name: "1073-session-terminal-after-reconnect")
        let reconnectedChange = changedPixelFraction(terminalBefore, terminalBody(app))
        XCTAssertLessThan(reconnectedChange, 0.02, "reconnecting cleared or redrew the session terminal (\(reconnectedChange) of it changed)")
        dismissTopSheet(app) // Terminal
        XCTAssertTrue(app.staticTexts["Manage Session"].waitForExistence(timeout: 10), "closing the terminal lost Manage Session: \(app.debugDescription)")
        dismissTopSheet(app) // Manage Session

        // 2. Mac Terminal over the chat's Settings.
        let gear = app.navigationBars.buttons["Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 30), app.debugDescription)
        gear.tap()
        XCTAssertTrue(app.buttons["settings-done"].waitForExistence(timeout: 30), app.debugDescription)
        guard let macTerminal = hittableElement(app, identifier: "settings-link-Mac Terminal", timeout: 30) else {
            return XCTFail("no Mac Terminal row: \(app.debugDescription)")
        }
        macTerminal.tap()
        XCTAssertTrue(terminalTitle.waitForExistence(timeout: 30), app.debugDescription)
        let checking = app.staticTexts["Checking your Mac…"]
        XCTAssertTrue(waitForAbsence(checking, timeout: 60), app.debugDescription)
        let placeholder = app.descendants(matching: .any)["mac-terminal-placeholder"].firstMatch
        XCTAssertTrue(placeholder.waitForExistence(timeout: 30), app.debugDescription)
        let macTerminalText = visibleText(placeholder)
        keepScreenshot(app, name: "1073-mac-terminal-before")
        returnFromAnotherApp(app)
        assertStays(app, presented: terminalTitle, never: checking, "Mac Terminal after returning to the app")
        XCTAssertEqual(visibleText(placeholder), macTerminalText, "Mac Terminal reloaded after returning to the app")
        keepScreenshot(app, name: "1073-mac-terminal-after-return")
        dismissTopSheet(app) // Mac Terminal
        XCTAssertTrue(app.buttons["settings-done"].waitForExistence(timeout: 10), "closing Mac Terminal lost Settings: \(app.debugDescription)")

        // 3. A draft in a sheet nested in a Settings sheet.
        guard let mcp = hittableElement(app, identifier: "settings-link-MCP Servers", timeout: 30) else {
            return XCTFail("no MCP Servers row: \(app.debugDescription)")
        }
        mcp.tap()
        let addServer = app.buttons["Add Server"]
        XCTAssertTrue(waitForEnabled(addServer, timeout: 60), app.debugDescription)
        addServer.tap()
        let name = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "For example, calendar")).firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 30), app.debugDescription)
        name.tap()
        name.typeText("draft-1073")
        returnFromAnotherApp(app)
        assertStays(app, presented: name, never: nil, "Add Server after returning to the app")
        XCTAssertEqual(name.value as? String, "draft-1073", "Add Server lost its draft after returning to the app")
        keepScreenshot(app, name: "1073-mcp-add-after-return")
        try forceReconnect(fixture)
        assertStays(app, presented: name, never: nil, "Add Server after reconnecting")
        XCTAssertEqual(name.value as? String, "draft-1073", "Add Server lost its draft after reconnecting")
        keepScreenshot(app, name: "1073-mcp-add-after-reconnect")
        // Add Server has no Done: a drag down closes it.
        let grabber = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
        grabber.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(waitForAbsence(name, timeout: 10), "Add Server did not close: \(app.debugDescription)")
        dismissTopSheet(app) // MCP Servers
        dismissTopSheet(app) // Settings

        // 4. The chat itself.
        XCTAssertTrue(composer.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertEqual(composer.value as? String, draft, "the unsent composer draft was lost")
    }

    /// Leaves for Safari and comes back, as a user copying something does: a
    /// real background and foreground of the scene.
    @MainActor
    private func returnFromAnotherApp(_ app: XCUIApplication) {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.activate()
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 20), "Safari did not become foreground")
        XCTAssertTrue(waitForBackground(app, timeout: 30), "Tron never reached the background")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), "Tron did not return to the foreground")
        safari.terminate()
    }

    /// Cuts the path long enough for the client's liveness deadline to retire
    /// the socket (ping 10 s + pong 8 s), then lets it reconnect.
    @MainActor
    private func forceReconnect(_ fixture: RealGatewayUIFixture) throws {
        try setProxyMode(fixture, mode: "blackhole")
        Thread.sleep(forTimeInterval: 25)
        try setProxyMode(fixture, mode: "pass")
        Thread.sleep(forTimeInterval: 10)
    }

    /// Samples for a few seconds: the sheet must stay presented in every sample
    /// (a close and re-present shows a gap) and its reload state must never show.
    @MainActor
    private func assertStays(_ app: XCUIApplication, presented: XCUIElement, never reload: XCUIElement?,
                             _ what: String, seconds: TimeInterval = 6, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(seconds)
        var gaps = 0, reloads = 0
        while Date() < deadline {
            if !presented.exists { gaps += 1 }
            if reload?.exists == true { reloads += 1 }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(gaps, 0, "\(what) closed or re-presented (\(gaps) samples without it)", file: file, line: line)
        XCTAssertEqual(reloads, 0, "\(what) reloaded (\(reloads) samples showed its loading state)", file: file, line: line)
    }

    @MainActor
    private func waitForValue(_ element: XCUIElement, _ value: String, timeout: TimeInterval) -> Bool {
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        return XCTWaiter().wait(for: [matches], timeout: timeout) == .completed
    }

    /// Every static text inside an element, in order: what the reader sees.
    @MainActor
    private func visibleText(_ element: XCUIElement) -> String {
        element.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: "|")
    }

    /// The terminal's rendered rows below the sheet chrome, above the keyboard.
    @MainActor
    private func terminalBody(_ app: XCUIApplication) -> CGImage? {
        let screenshot = app.screenshot().image
        let scale = screenshot.scale
        return screenshot.cgImage?.cropping(to: CGRect(x: 16 * scale, y: 130 * scale,
                                                       width: 340 * scale, height: 160 * scale))
    }

    /// Settings surfaces serve the schema's keys (docs/settings-model.md 7.7). For
    /// each surface, every key whose layers include one the surface's target has
    /// is a reachable row with a layer badge and a value; a key with none of them
    /// has no row. A layer the surface does not own offers its "Edit at …" path,
    /// and an accepted edit reads back after reopening, from the Gateway's
    /// resolution. Expectations come from the fixture Gateway's own schema
    /// inventory (`TRON_E2E_SETTINGS_INVENTORY`), never from a Swift key list.
    /// Every settings sheet opens on its content against a real Gateway. A schema
    /// section sheet reads the snapshot its parent already has, so it never shows a
    /// loading state; each sheet's first frames are kept to review the rest.
    @MainActor
    func testSettingsSheetsOpenStably() throws {
        continueAfterFailure = true
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let app = launchApp()
        defer { app.terminate() }
        open(fixture.invitationLink())
        completeFirstRunSetup(app, inWorkspace: fixture.workspace)
        XCTAssertTrue(waitForHittable(app.buttons["dashboard.menu"], timeout: 90), app.debugDescription)
        createSession(app, inWorkspace: fixture.workspace)
        let loading = app.staticTexts["Loading settings…"]
        func burst(_ name: String) {
            for index in 0..<10 {
                let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                shot.name = String(format: "%@-%02d", name, index)
                shot.lifetime = .keepAlways
                add(shot)
            }
        }
        func openSheet(_ identifier: String, _ name: String, section: String? = nil) {
            guard let button = app.buttons.matching(identifier: identifier).allElementsBoundByIndex.last else {
                XCTFail("no \(identifier): \(app.debugDescription)"); return
            }
            for _ in 0..<12 where !button.isHittable { app.swipeUp() }
            button.tap()
            if let section {
                XCTAssertTrue(app.descendants(matching: .any)["settings-section-\(section)-detail"].waitForExistence(timeout: 2),
                              "the \(name) sheet did not open on its content")
                XCTAssertFalse(loading.exists, "the \(name) sheet showed a loading state")
            }
            burst(name)
        }

        // Manage Session: this chat's settings card.
        let ring = app.buttons["session-context-button"]
        XCTAssertTrue(ring.waitForExistence(timeout: 60), app.debugDescription)
        ring.tap()
        XCTAssertTrue(app.staticTexts["Manage Session"].waitForExistence(timeout: 30), app.debugDescription)
        burst("manage-session")
        for _ in 0..<4 { app.swipeUp() }
        burst("manage-session-rows")
        openSheet("chat-settings-link", "chat-settings")
        for section in ["model", "run"] {
            XCTAssertTrue(app.descendants(matching: .any)["settings-section-\(section)-detail"].exists)
            XCTAssertFalse(app.buttons["settings-section-\(section)-open"].exists)
            burst("chat-\(section)-inline")
        }
        dismissTopSheet(app) // Chat Settings
        dismissTopSheet(app) // Manage Session

        // Settings: this Mac.
        let gear = app.navigationBars.buttons["Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 30), app.debugDescription)
        gear.tap()
        XCTAssertTrue(app.buttons["settings-done"].waitForExistence(timeout: 30), app.debugDescription)
        burst("settings")
        openSheet("settings-section-model-open", "mac-model", section: "model"); dismissTopSheet(app)
        openSheet("settings-section-run-open", "mac-run", section: "run"); dismissTopSheet(app)
        openSheet("settings-section-permissions-open", "mac-permissions", section: "permissions")
        openSheet("settings-instances-permissions.floor-open", "agent-approvals"); dismissTopSheet(app); dismissTopSheet(app)
        openSheet("settings-section-tools-open", "mac-tools", section: "tools"); dismissTopSheet(app)
        for (title, name) in [("MCP Servers", "mcp"), ("Extensions", "extensions"), ("Hooks", "hooks"),
                              ("Model Providers", "providers"), ("Custom Models", "custom-models"), ("Setup", "setup")] {
            openSheet("settings-link-\(title)", name); dismissTopSheet(app)
        }
    }

    /// Settings clarity (#939) against the real Gateway: Accounts leads with
    /// Connections, Push Notifications is its own row leading This iPhone (#956),
    /// and Tools & Diagnostics is the last group (#1030); provenance pills carry the
    /// Gateway's wording and name a per-model value's model; a text setting's
    /// return key reads Done, commits through the change path and dismisses the
    /// keyboard; an add-value row shows the schema's example and format. The kept
    /// screenshots are the approval and review evidence for each sheet.
    @MainActor
    func testSettingsClarityPillsTextDoneAndAccountsFirst() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let schema = try SettingsSchemaInventory.fromEnvironment()
        let sources = Set(schema.layerLabels.values)
        try addMcpServerOutsideTron(fixture.agentDirectory, name: "docs-server")
        let app = launchApp()
        defer { app.terminate() }
        open(fixture.invitationLink())
        completeFirstRunSetup(app, inWorkspace: fixture.workspace)
        XCTAssertTrue(waitForHittable(app.buttons["dashboard.menu"], timeout: 90), app.debugDescription)
        createSession(app, inWorkspace: fixture.workspace) {
            // New Session: Project Settings is a setup card like its neighbours, and the
            // Model card's source pill uses the Gateway's wording inside the card.
            let project = app.buttons["project-settings-link"]
            XCTAssertTrue(project.waitForExistence(timeout: 30), app.debugDescription)
            let projectName = URL(fileURLWithPath: fixture.workspace).lastPathComponent
            let projectValue = project.value as? String ?? ""
            XCTAssertTrue(project.label == "Project Settings" && projectValue.contains(projectName)
                          && projectValue.contains("Settings in this project's .pi folder."),
                          "the Project Settings card shows its value and subtext: \(project.label) / \(projectValue)")
            // One card geometry: the same width and left edge as its Workspace neighbour.
            let workspaceCard = app.buttons["new-session-card.Workspace"]
            XCTAssertEqual(project.frame.minX, workspaceCard.frame.minX, accuracy: 1)
            XCTAssertEqual(project.frame.width, workspaceCard.frame.width, accuracy: 1)
            let modelCard = app.buttons["new-session-card.Model"]
            XCTAssertTrue(self.waitUntil(timeout: 30) { sources.contains { modelCard.label.contains($0) } },
                          "the Model card names its source in the Gateway's wording: \(modelCard.label)")
            // Reveal the Model card under the medium detent for the evidence screenshot.
            for _ in 0..<3 where !modelCard.isHittable || modelCard.frame.maxY > app.frame.maxY - 40 { app.swipeUp() }
            self.keepScreenshot(app, name: "939-new-session")
        }

        let gear = app.navigationBars.buttons["Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 30), app.debugDescription)
        gear.tap()
        XCTAssertTrue(app.buttons["settings-done"].waitForExistence(timeout: 30), app.debugDescription)
        // Accounts is the first group: Connections, then providers; the agent's own
        // sections follow, then This iPhone, led by Push Notifications, and last
        // Tools & Diagnostics (#1030).
        let order = ["settings-link-Connections", "settings-link-Model Providers", "settings-section-model-open",
                     "settings-link-Hooks", "settings-link-Push Notifications", "settings-link-Appearance",
                     "settings-link-Sessions", "settings-link-Mac Terminal", "settings-link-Experimental",
                     "settings-link-Setup", "settings-link-Logs"].map { app.buttons[$0] }
        XCTAssertTrue(order[2].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(order.allSatisfy(\.exists), app.debugDescription)
        XCTAssertEqual(order.map(\.frame.minY), order.map(\.frame.minY).sorted(), "Settings must open with Accounts: \(order.map(\.frame))")
        XCTAssertTrue(app.staticTexts["Paired Macs and authorized devices"].exists, "Connections no longer offers push")
        keepScreenshot(app, name: "939-settings-root-order")

        // Model: a layer pill in the Gateway's wording and the per-model pill by display name.
        openSettingsSection(app, "model")
        let thinking = settingRows(app, key: "model.thinking[role=chat]").firstMatch
        XCTAssertTrue(thinking.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(waitUntil(timeout: 30) { self.badgeLabels(thinking).contains(where: sources.contains) },
                      "the Thinking row must say where its value comes from: \(badgeLabels(thinking))")
        // The pill reads "For <name>"; its accessible text appends the provider/id as detail.
        let modelPill = badgeLabels(thinking).first { $0.hasPrefix("For ") }
        let pillText = modelPill?.components(separatedBy: ", ").first ?? ""
        XCTAssertNotNil(modelPill, "a per-model value names its model: \(badgeLabels(thinking))")
        XCTAssertFalse(pillText.contains("/"), "the model pill uses the display name, not provider/id: \(modelPill ?? "")")
        keepScreenshot(app, name: "939-model-pills")
        dismissTopSheet(app)

        // Context: Summary instructions commits on the keyboard's Done and the keyboard goes away.
        openSettingsSection(app, "context")
        keepScreenshot(app, name: "939-context-pills")
        // The settings row combines its labels, so the field is found inside its row.
        let instructionsRow = settingRow(app, key: "context.compaction.instructions")
        XCTAssertTrue(instructionsRow.waitForExistence(timeout: 30), app.debugDescription)
        let field: XCUIElement? = instructionsRow.textFields.firstMatch
        for _ in 0..<10 where !(field?.isHittable ?? false) { app.swipeUp() }
        XCTAssertTrue(field?.isHittable ?? false, "Summary instructions has no field: \(app.debugDescription)")
        XCTAssertEqual(field?.placeholderValue, "Keep file paths and open decisions.", "the field shows the schema's example")
        field?.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10), "the field did not raise the keyboard")
        field?.typeText("Keep file paths.")
        let done = keyboard.buttons.matching(NSPredicate(format: "label ==[c] %@", "done")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), "the return key must read Done: \(keyboard.debugDescription)")
        keepScreenshot(app, name: "939-text-field-done-key")
        done.tap()
        XCTAssertTrue(waitForNonExistence(keyboard, timeout: 10), "Done must dismiss the keyboard")
        XCTAssertTrue(waitUntil(timeout: 60) {
            let compaction = (try? self.macSettingsDocument(fixture.agentDirectory))?["compaction"] as? [String: Any]
            return compaction?["instructions"] as? String == "Keep file paths."
        }, "Done must commit Summary instructions through the change path to the Mac settings.json")
        XCTAssertTrue(waitForBadge(instructionsRow, schema.label(for: "mac"), timeout: 30),
                      "the committed value is set on the Mac: \(badgeLabels(instructionsRow))")
        keepScreenshot(app, name: "939-text-field-committed")
        dismissTopSheet(app)

        // MCP Servers: the server rows sit in the shared glass group.
        let mcpLink = app.buttons["settings-link-MCP Servers"]
        for _ in 0..<12 where !mcpLink.isHittable { app.swipeUp() }
        mcpLink.tap()
        let server = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "docs-server")).firstMatch
        XCTAssertTrue(server.waitForExistence(timeout: 60), app.debugDescription)
        keepScreenshot(app, name: "939-mcp-servers")
        dismissTopSheet(app)

        // Extensions: the npm command and a search path say what to enter, with an example.
        let extensionsLink = app.buttons["settings-link-Extensions"]
        for _ in 0..<12 where !extensionsLink.isHittable { app.swipeUp() }
        extensionsLink.tap()
        for (key, name) in [("sources.npmCommand", "npm"), ("sources.extensions", "search-path")] {
            guard let row = hittableElement(app, identifier: settingRowToken(key), timeout: 60) else {
                XCTFail("Extensions has no \(key) row: \(app.debugDescription)"); return
            }
            // The row's trailing value pill opens its editor sheet.
            (row.buttons.allElementsBoundByIndex.last ?? row).tap()
            // The add-value row combines its labels; its field is the one text field on the editor.
            let value = app.textFields.matching(NSPredicate(format: "placeholderValue != nil AND placeholderValue != ''")).firstMatch
            XCTAssertTrue(value.waitForExistence(timeout: 15), "the \(key) sheet has no add-value field: \(app.debugDescription)")
            XCTAssertNotEqual(value.placeholderValue ?? "", "Value", "the placeholder must be a real example")
            XCTAssertFalse((value.placeholderValue ?? "").isEmpty, "the add-value field shows the schema's example")
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "For example:")).firstMatch.exists,
                          "the add-value row says what to enter: \(app.debugDescription)")
            if key == "sources.npmCommand" {
                XCTAssertEqual(value.placeholderValue, "pnpm")
                value.tap()
                value.typeText("pnpm")
                let add = app.keyboards.buttons.matching(NSPredicate(format: "label ==[c] %@", "done")).firstMatch
                XCTAssertTrue(add.waitForExistence(timeout: 5), "the add-value return key must read Done")
                add.tap()
                XCTAssertTrue(waitForNonExistence(app.keyboards.firstMatch, timeout: 10), "Done must dismiss the keyboard")
                XCTAssertTrue(app.staticTexts["pnpm"].waitForExistence(timeout: 5), "Done must add the typed value to the list")
            }
            keepScreenshot(app, name: "939-add-value-\(name)")
            dismissTopSheet(app)
        }
        dismissTopSheet(app) // Extensions

        // Connections (Accounts) and the Push Notifications sheet (This iPhone).
        for (title, marker, name) in [("Connections", "Paired Macs", "connections"), ("Push Notifications", "Input needed", "push")] {
            let link = app.buttons["settings-link-\(title)"]
            for _ in 0..<20 where !link.isHittable {
                if title == "Connections" { app.swipeDown() } else { app.swipeUp() }
            }
            link.tap()
            func labelled(_ text: String) -> XCUIElement {
                app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", text)).firstMatch
            }
            XCTAssertTrue(labelled(marker).waitForExistence(timeout: 30), "\(title) did not open: \(app.debugDescription)")
            if title == "Connections" {
                XCTAssertFalse(labelled("Input needed").exists, "push alerts moved to their own sheet")
                assertToolbarTint(app, title: "Connections")
                // An authorized device's detail sheet (its row reads "Details for
                // <device> on <Mac>"): its pencil and Done take the
                // Connections tint of its title, not a hard-coded green (#963).
                let device = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Details for ' AND label CONTAINS ' on '")).firstMatch
                XCTAssertTrue(device.waitForExistence(timeout: 30), app.debugDescription)
                let label = device.label.dropFirst("Details for ".count)
                let deviceName = String(label[..<(label.range(of: " on ", options: .backwards)?.lowerBound ?? label.endIndex)])
                device.tap()
                XCTAssertTrue(app.buttons["device-rename"].waitForExistence(timeout: 30), app.debugDescription)
                assertToolbarTint(app, title: deviceName)
                keepScreenshot(app, name: "963-device-detail")
                dismissTopSheet(app)
            }
            keepScreenshot(app, name: "939-\(name)")
            dismissTopSheet(app)
        }
    }

    @MainActor
    func testChatSettingsServeEveryKeyAndEditAtChatLayer() throws {
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

        // Manage Session is reached through the composer's context control; the
        // chat navigation-bar gear opens Mac Settings, not Manage Session.
        let manageSessionButton = app.buttons["session-context-button"]
        XCTAssertTrue(manageSessionButton.waitForExistence(timeout: 60), app.debugDescription)
        XCTAssertTrue(manageSessionButton.label.contains("Manage Session"), manageSessionButton.debugDescription)
        manageSessionButton.tap()
        XCTAssertTrue(app.staticTexts["Manage Session"].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.buttons["chat-settings-link"].waitForExistence(timeout: 15),
                      "Manage Session must link to Chat Settings: \(app.debugDescription)")
        XCTAssertTrue(app.buttons["project-settings-link"].exists,
                      "Manage Session must retain the Project Settings row")
        app.buttons["chat-settings-link"].tap()
        XCTAssertTrue(app.staticTexts["Chat Settings"].waitForExistence(timeout: 15), app.debugDescription)
        // Chat Settings serves Chat-layer keys and can also show inherited values
        // from other layers. Those owners are exhaustively checked on Project and
        // Mac Settings below; custom Mac-only rows stay in their owning UI.
        coverage["chat-settings"] = assertSettingsSurface(app, name: "chat-settings",
            layers: ["chat"], schema: schema, allowsInheritedRows: true, inlineSections: true)
        XCTAssertTrue(app.descendants(matching: .any)["settings-section-run-detail"].exists)
        let chatLayerRetry = toggleSetting(app, key: "run.retry.enabled", expectingBadge: schema.label(for: "chat"))
        XCTAssertNotEqual(chatLayerRetry.before, chatLayerRetry.after, "the Chat-layer edit was not accepted")
        dismissTopSheet(app) // Chat Settings
        dismissTopSheet(app) // Manage Session
        XCTAssertTrue(waitForNonExistence(app.staticTexts["Manage Session"], timeout: 15))
        manageSessionButton.tap()
        XCTAssertTrue(app.staticTexts["Manage Session"].waitForExistence(timeout: 30), app.debugDescription)
        app.buttons["chat-settings-link"].tap()
        XCTAssertTrue(app.staticTexts["Chat Settings"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["settings-section-run-detail"].exists)
        let reopenedRetry = topSwitchRow(app, key: "run.retry.enabled")
        XCTAssertTrue(waitForBadge(reopenedRetry, schema.label(for: "chat"), timeout: 30),
                      "the reopened Chat Settings must show the Chat badge: \(reopenedRetry.debugDescription)")
        XCTAssertEqual(switchValue(reopenedRetry), chatLayerRetry.after, "the reopened Chat value is not the accepted value")
        keepScreenshot(app, name: "settings-surface-chat-settings-chat-edit")
        dismissTopSheet(app) // Chat Settings
        attachSettingsCoverage(coverage, schema: schema)
    }

    @MainActor
    func testProjectSettingsServeEveryKeyAndEditAtProjectLayer() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let schema = try SettingsSchemaInventory.fromEnvironment()
        let app = launchApp()
        defer { app.terminate() }
        open(fixture.invitationLink())
        completeFirstRunSetup(app, inWorkspace: fixture.workspace)
        XCTAssertTrue(waitForHittable(app.buttons["dashboard.menu"], timeout: 90), app.debugDescription)
        createSession(app, inWorkspace: fixture.workspace)
        let manageSessionButton = app.buttons["session-context-button"]
        XCTAssertTrue(manageSessionButton.waitForExistence(timeout: 60), app.debugDescription)
        manageSessionButton.tap()
        XCTAssertTrue(app.staticTexts["Manage Session"].waitForExistence(timeout: 30), app.debugDescription)
        var coverage: [String: SurfaceCoverage] = [:]

        // The Project card, the same component Manage Session and the dashboard
        // open (the dashboard path is TronNewSessionUITests): the Project layer and
        // the Mac key that qualifies by this project.
        openProjectCard(app)
        coverage["project"] = assertSettingsSurface(app, name: "project", layers: ["project", "mac"], schema: schema,
                                                     sectionDestinations: ["sources": "Extensions"])
        openSettingsSection(app, "context")
        // Setup opened the workspace without its resources: the untrusted Project
        // layer refuses the write and the row says why (decision 2, doc 3.5).
        let untrustedRow = topSwitchRow(app, key: "context.compaction.enabled")
        let untrustedSwitch = untrustedRow.switches.firstMatch
        let untrustedValue = switchValue(untrustedRow)
        untrustedSwitch.tap()
        XCTAssertTrue(waitUntil(timeout: 30) {
            self.badgeLabels(untrustedRow).contains { $0.contains("Trust this project") }
        }, "an untrusted Project write must be refused on its row: \(badgeLabels(untrustedRow))")
        XCTAssertEqual(switchValue(untrustedRow), untrustedValue, "a refused Project write must not change the value")
        dismissTopSheet(app)
        // Trust it through the card's own Review trust, then reopen the card.
        let review = app.buttons["Review trust"]
        revealBelowNavigationBar(app, review)
        review.tap()
        let trustProject = app.buttons["Trust Project"]
        XCTAssertTrue(trustProject.waitForExistence(timeout: 30), "Review trust must offer Trust Project: \(app.debugDescription)")
        for _ in 0..<10 where !trustProject.isHittable { app.swipeUp() }
        trustProject.tap()
        XCTAssertTrue(waitForNonExistence(trustProject, timeout: 60), "the trust decision was not accepted")
        for _ in 0..<3 where !app.buttons["project-settings-link"].isHittable { dismissTopSheet(app) }
        XCTAssertTrue(waitUntil(timeout: 15) { app.buttons["project-settings-link"].isHittable }, "dismissing must return to Manage Session")
        openProjectCard(app)
        openSettingsSection(app, "context")
        let projectEdit = toggleSetting(app, key: "context.compaction.enabled", expectingBadge: schema.label(for: "project"))
        XCTAssertNotEqual(projectEdit.before, projectEdit.after, "the Project-layer edit was not accepted")
        dismissTopSheet(app)
        openSettingsSection(app, "permissions")
        // The project's trust decision is a Mac key qualified by this project: its
        // row offers Edit at Mac, which opens the Mac layer's Settings.
        // SwiftUI also exposes the containing row with this identifier. Tap the
        // named action, not the row's centre, which does not invoke the editor.
        let trustEditor = revealedElement(app, where: NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@ AND label == %@",
            settingRowToken("permissions.projectTrust"), "-edit-layer", "Edit at Mac"))
        XCTAssertNotNil(trustEditor, "the project trust row must offer Edit at Mac on the Project card")
        trustEditor?.tap()
        let trustSheetDone = app.buttons["settings-done"]
        XCTAssertTrue(trustSheetDone.waitForExistence(timeout: 15), "Edit at Mac on the Project card must open Settings: \(app.debugDescription)")
        trustSheetDone.tap()
        XCTAssertTrue(waitForNonExistence(trustSheetDone, timeout: 15), "the layer editor must dismiss")
        dismissTopSheet(app) // Permissions Settings
        dismissTopSheet(app) // Project settings
        XCTAssertTrue(waitUntil(timeout: 15) { app.buttons["project-settings-link"].isHittable }, "dismissing the Project card must return to Manage Session")
        openProjectCard(app)
        openSettingsSection(app, "context")
        let reopenedCompaction = topSwitchRow(app, key: "context.compaction.enabled")
        XCTAssertTrue(waitForBadge(reopenedCompaction, schema.label(for: "project"), timeout: 30),
                      "the reopened Project card must show the Project badge: \(reopenedCompaction.debugDescription)")
        XCTAssertEqual(switchValue(reopenedCompaction), projectEdit.after, "the reopened Project value is not the accepted value")
        keepScreenshot(app, name: "settings-surface-project-layer-edit")
        dismissTopSheet(app) // Context Settings
        dismissTopSheet(app) // Project settings
        XCTAssertTrue(waitUntil(timeout: 15) { app.buttons["project-settings-link"].isHittable }, "dismissing the Project card must return to Manage Session")

        dismissTopSheet(app)
        XCTAssertTrue(waitForNonExistence(app.staticTexts["Manage Session"], timeout: 15))

        attachSettingsCoverage(coverage, schema: schema)
    }

    @MainActor
    func testMacSettingsServeEveryKeyAndEditAtMacLayer() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let schema = try SettingsSchemaInventory.fromEnvironment()
        let app = launchApp()
        defer { app.terminate() }
        open(fixture.invitationLink())
        completeFirstRunSetup(app, inWorkspace: fixture.workspace)
        XCTAssertTrue(waitForHittable(app.buttons["dashboard.menu"], timeout: 90), app.debugDescription)
        createSession(app, inWorkspace: fixture.workspace)
        var coverage: [String: SurfaceCoverage] = [:]

        // Settings (Mac layer) from the chat navigation-bar gear: one Mac key edits and reads back.
        let macSettingsGear = app.navigationBars.buttons["Settings"]
        func openMacSettings() {
            XCTAssertTrue(macSettingsGear.waitForExistence(timeout: 30), app.debugDescription)
            macSettingsGear.tap()
            XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 30), app.debugDescription)
        }
        openMacSettings()
        coverage["settings"] = assertSettingsSurface(app, name: "settings", layers: ["mac"], schema: schema,
                                                      sectionDestinations: ["sources": "Extensions", "setup": "Setup"])
        openSettingsSection(app, "setup", linkLabel: "Setup")
        let macEdit = toggleSetting(app, key: "setup.installTelemetry", expectingBadge: schema.label(for: "mac"))
        XCTAssertNotEqual(macEdit.before, macEdit.after, "the Mac-layer edit was not accepted")
        dismissTopSheet(app) // Setup Settings
        dismissTopSheet(app) // Settings
        XCTAssertTrue(waitForNonExistence(app.staticTexts["Settings"], timeout: 15))
        openMacSettings()
        openSettingsSection(app, "setup", linkLabel: "Setup")
        let reopenedTelemetry = topSwitchRow(app, key: "setup.installTelemetry")
        XCTAssertTrue(waitForBadge(reopenedTelemetry, schema.label(for: "mac"), timeout: 30),
                      "the reopened Settings must show the Mac badge: \(reopenedTelemetry.debugDescription)")
        XCTAssertEqual(switchValue(reopenedTelemetry), macEdit.after, "the reopened Mac value is not the accepted value")
        keepScreenshot(app, name: "settings-surface-settings-mac-edit")
        dismissTopSheet(app) // Setup Settings
        dismissTopSheet(app) // Settings
        XCTAssertTrue(waitForNonExistence(app.staticTexts["Settings"], timeout: 15))

        attachSettingsCoverage(coverage, schema: schema)
    }

    // Each surface and outside-file reconciliation has its own fresh fixture,
    // preserving all assertions while keeping each gate shard bounded.
    @MainActor
    func testSettingsOutsideChangesAndBuiltinExtensionPersist() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let schema = try SettingsSchemaInventory.fromEnvironment()
        let app = launchApp()
        defer { app.terminate() }
        open(fixture.invitationLink())
        completeFirstRunSetup(app, inWorkspace: fixture.workspace)
        XCTAssertTrue(waitForHittable(app.buttons["dashboard.menu"], timeout: 90), app.debugDescription)
        createSession(app, inWorkspace: fixture.workspace)
        let macSettingsGear = app.navigationBars.buttons["Settings"]
        func openMacSettings() {
            XCTAssertTrue(macSettingsGear.waitForExistence(timeout: 30), app.debugDescription)
            macSettingsGear.tap()
            XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 30), app.debugDescription)
        }
        openMacSettings()
        openSettingsSection(app, "setup", linkLabel: "Setup")
        let macEdit = toggleSetting(app, key: "setup.installTelemetry", expectingBadge: schema.label(for: "mac"))
        dismissTopSheet(app) // Setup
        dismissTopSheet(app) // Settings
        XCTAssertTrue(waitForNonExistence(app.staticTexts["Settings"], timeout: 15))

        // An outside edit replaces the value Tron wrote (settings-model.md 5.6): the
        // reopened row says so and Apply again writes Tron's value back.
        try editMacSettingsOutsideTron(fixture.agentDirectory) { document in
            document["enableInstallTelemetry"] = macEdit.before == "1"
        }
        openMacSettings()
        openSettingsSection(app, "setup", linkLabel: "Setup")
        let outsideSummary = settingRow(app, key: "setup.installTelemetry")
        // The badge's accessible label carries its detail ("Changed outside Tron, Mac: On → Off").
        XCTAssertTrue(waitUntil(timeout: 30) { self.badgeLabels(outsideSummary).contains { $0.hasPrefix("Changed outside Tron") } },
                      "an outside edit of Tron's value must be shown: \(badgeLabels(outsideSummary))")
        // An actionable outside-change badge promotes this row to a detail link;
        // its toggle and Apply again belong to that child, not the summary row.
        let outsideEditor = hittableElement(app, identifier: settingRowToken("setup.installTelemetry") + "-open")
        XCTAssertNotNil(outsideEditor, "the outside change must open its value and actions")
        outsideEditor?.tap()
        let outsideRow = topSwitchRow(app, key: "setup.installTelemetry")
        XCTAssertEqual(switchValue(outsideRow), macEdit.before, "the live value must follow the edited store")
        let applyAgain = hittableElement(app, identifier: settingRowToken("setup.installTelemetry") + "-applyAgain", timeout: 120)
        XCTAssertNotNil(applyAgain, "the outside change of Tron's value must offer Apply again: \(app.debugDescription)")
        keepScreenshot(app, name: "settings-surface-outside-change-apply-again")
        applyAgain?.tap()
        XCTAssertTrue(waitUntil(timeout: 60) {
            self.switchValue(outsideRow) == macEdit.after && !self.badgeLabels(outsideRow).contains { $0.hasPrefix("Changed outside Tron") }
        }, "Apply again must restore Tron's value and clear the outside mark: \(badgeLabels(outsideRow))")

        // Clearing the outside marker removes its detail link and can retire
        // that child. Return to the actual Settings root, not a fixed sheet count.
        for _ in 0..<3 {
            if app.buttons["settings-done"].isHittable { break }
            dismissTopSheet(app)
        }
        XCTAssertTrue(app.buttons["settings-done"].isHittable, "Apply again must return to Settings")
        // A hand-built screen on the same change path: Extensions' Built-in switch
        // writes `sources.extensions` at the Mac layer (no legacy document read).
        let extensionsLink = app.buttons["settings-link-Extensions"]
        for _ in 0..<40 where !extensionsLink.isHittable { app.swipeDown() }
        extensionsLink.tap()
        let toolSearch = app.switches["Tool search"]
        XCTAssertTrue(toolSearch.waitForExistence(timeout: 30), "Extensions must show the Built-in switches: \(app.debugDescription)")
        for _ in 0..<10 where !toolSearch.isHittable { app.swipeUp() }
        let toolSearchBefore = toolSearch.value as? String
        toolSearch.tap()
        XCTAssertTrue(waitUntil(timeout: 30) { (toolSearch.value as? String) != toolSearchBefore }, "the Built-in switch did not change")
        XCTAssertTrue(waitUntil(timeout: 30) {
            let entries = (try? self.macSettingsDocument(fixture.agentDirectory))?["extensions"] as? [String] ?? []
            return entries.contains("-builtin:tool-search") == (toolSearchBefore == "1")
        }, "turning Tool search off must write -builtin:tool-search to the Mac settings.json")
        keepScreenshot(app, name: "settings-surface-builtin-extension-switch")
        // Extensions is a progressive child of Settings: close it, then Settings.
        for _ in 0..<3 where app.staticTexts["Settings"].exists || app.switches["Tool search"].exists { dismissTopSheet(app); Thread.sleep(forTimeInterval: 1) }
        XCTAssertTrue(waitForNonExistence(app.staticTexts["Settings"], timeout: 15))

        // MCP servers keep their own owner (settings-model.md 5.6a): a server added to
        // the Mac mcp.json outside Tron while the MCP screen is open reaches it with no
        // reload (`mcp.changed` from the Gateway's file watch), and Changes records it by name.
        openMacSettings()
        let mcpLink = app.buttons["settings-link-MCP Servers"]
        for _ in 0..<20 where !mcpLink.isHittable { app.swipeUp() }
        for _ in 0..<40 where !mcpLink.isHittable { app.swipeDown() }
        mcpLink.tap()
        XCTAssertTrue(app.staticTexts["MCP Servers"].waitForExistence(timeout: 30), app.debugDescription)
        let outsideServer = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "outside-mcp")).firstMatch
        XCTAssertFalse(outsideServer.exists, "the fixture must start without the outside server")
        try addMcpServerOutsideTron(fixture.agentDirectory, name: "outside-mcp")
        XCTAssertTrue(outsideServer.waitForExistence(timeout: 90),
                      "an outside mcp.json addition must reach the open MCP screen without a reload: \(app.debugDescription)")
        keepScreenshot(app, name: "settings-mcp-outside-addition")
        dismissTopSheet(app)
        // Settings' own row is also titled "MCP Servers": the screen is gone once its server row is.
        XCTAssertTrue(waitUntil(timeout: 15) { !outsideServer.exists && mcpLink.exists }, "dismissing MCP Servers must return to Settings")
        for _ in 0..<40 where !app.buttons["Changes"].isHittable { app.swipeDown() }
        app.buttons["Changes"].tap()
        let outsideEntry = app.staticTexts["MCP server outside-mcp"]
        XCTAssertTrue(outsideEntry.waitForExistence(timeout: 60), "Changes must list the outside MCP addition by name: \(app.debugDescription)")
        keepScreenshot(app, name: "settings-changes-outside-mcp")
        for _ in 0..<3 where app.staticTexts["Settings"].exists || outsideEntry.exists { dismissTopSheet(app); Thread.sleep(forTimeInterval: 1) }
        XCTAssertTrue(waitForNonExistence(app.staticTexts["Settings"], timeout: 15))

    }

    /// #243: a package whose `engines.node` excludes the Mac Gateway's Node still
    /// installs and loads (D-2 warns, never refuses), and Extensions says so: the
    /// Installed row carries the short tag and its detail sheet explains the
    /// mismatch with the existing notice. A package whose range the runtime meets
    /// carries no tag. The kept screenshots are the approval evidence.
    @MainActor
    func testExtensionsFlagsAPackageThatNeedsAnotherNode() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let directory = try XCTUnwrap(fixture.agentDirectory, "run through scripts/ios-gateway-e2e-test run-ui to name the fixture's agent directory")
        for (name, range) in [("future-node-package", ">=999.0.0"), ("current-node-package", ">=1")] {
            let root = URL(fileURLWithPath: directory).appendingPathComponent(name)
            let skill = root.appendingPathComponent("skills/\(name)")
            try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["name": name, "version": "1.0.0", "engines": ["node": range],
                                                        "pi": ["skills": ["skills"]]])
                .write(to: root.appendingPathComponent("package.json"))
            try "---\nname: \(name)\ndescription: Fixture skill.\n---\nFixture.\n"
                .write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        try editMacSettingsOutsideTron(directory) { document in
            document["packages"] = ["./future-node-package", "./current-node-package"]
        }
        let app = launchApp()
        defer { app.terminate() }
        open(fixture.invitationLink())
        completeFirstRunSetup(app, inWorkspace: fixture.workspace)
        XCTAssertTrue(waitForHittable(app.buttons["dashboard.menu"], timeout: 90), app.debugDescription)
        createSession(app, inWorkspace: fixture.workspace)
        let gear = app.navigationBars.buttons["Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 30), app.debugDescription)
        gear.tap()
        XCTAssertTrue(app.buttons["settings-done"].waitForExistence(timeout: 30), app.debugDescription)
        let extensionsLink = app.buttons["settings-link-Extensions"]
        for _ in 0..<20 where !extensionsLink.isHittable { app.swipeUp() }
        extensionsLink.tap()
        let flagged = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "./future-node-package.")).firstMatch
        let met = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "./current-node-package.")).firstMatch
        XCTAssertTrue(flagged.waitForExistence(timeout: 60), "Extensions must list the fixture package: \(app.debugDescription)")
        XCTAssertTrue(flagged.label.contains("Needs Node >=999.0.0"), "the mismatched package's row must carry the tag: \(flagged.label)")
        XCTAssertTrue(met.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(met.label.contains("Needs Node"), "a met range carries no tag: \(met.label)")
        for _ in 0..<10 where !flagged.isHittable { app.swipeUp() }
        keepScreenshot(app, name: "extensions-package-needs-node-row")
        flagged.tap()
        let notice = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "This package needs Node >=999.0.0, but this Mac runs Node ")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 30), "the detail sheet must explain the mismatch: \(app.debugDescription)")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "future-node-package")).firstMatch.exists, "the warned package still loads and provides its skill: \(app.debugDescription)")
        keepScreenshot(app, name: "extensions-package-needs-node-detail")
    }

    // MARK: - Settings surface helpers

    /// A hand edit of the fixture's Mac `settings.json`, as an editor would make
    /// it: write a sibling file, then rename it over the store.
    private func macSettingsDocument(_ agentDirectory: String?) throws -> [String: Any] {
        let directory = try XCTUnwrap(agentDirectory)
        let data = try Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent("settings.json"))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func editMacSettingsOutsideTron(_ agentDirectory: String?, _ edit: (inout [String: Any]) -> Void) throws {
        let directory = try XCTUnwrap(agentDirectory, "run through scripts/ios-gateway-e2e-test run-ui to name the fixture's agent directory")
        let store = URL(fileURLWithPath: directory).appendingPathComponent("settings.json")
        var document = (try JSONSerialization.jsonObject(with: Data(contentsOf: store)) as? [String: Any]) ?? [:]
        edit(&document)
        let staged = store.deletingLastPathComponent().appendingPathComponent("settings.json.outside-edit")
        try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted]).write(to: staged)
        _ = try FileManager.default.replaceItemAt(store, withItemAt: staged)
    }

    /// A hand edit of the fixture's Mac `mcp.json` adding one HTTP server, by rename-replace.
    /// The loopback port refuses at once, so listing it opens no external connection.
    private func addMcpServerOutsideTron(_ agentDirectory: String?, name: String) throws {
        let directory = try XCTUnwrap(agentDirectory, "run through scripts/ios-gateway-e2e-test run-ui to name the fixture's agent directory")
        let store = URL(fileURLWithPath: directory).appendingPathComponent("mcp.json")
        var document = ((try? Data(contentsOf: store)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        var servers = document["mcpServers"] as? [String: Any] ?? [:]
        servers[name] = ["url": "http://127.0.0.1:1/\(name)"]
        document["mcpServers"] = servers
        let staged = store.deletingLastPathComponent().appendingPathComponent("mcp.json.outside-edit")
        try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted]).write(to: staged)
        if FileManager.default.fileExists(atPath: store.path) {
            _ = try FileManager.default.replaceItemAt(store, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: store)
        }
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
    /// Floor and enrolled-device instances are served by the Mac target alone
    /// (`settings-resolver.ts` `instances`). Mac project/device instances exist
    /// only when a trust decision/enrollment exists; this fixture enrolls no SSH key.
    @MainActor
    private func assertSettingsSurface(_ app: XCUIApplication, name: String, layers: Set<String>,
                                       schema: SettingsSchemaInventory,
                                       allowsInheritedRows: Bool = false,
                                       inlineSections: Bool = false,
                                       sectionDestinations: [String: String] = [:]) -> SurfaceCoverage {
        var coverage = SurfaceCoverage()
        let isMacTarget = layers == ["mac"]
        let allLayerLabels = Set(schema.layerLabels.values)
        var groups: [String] = []
        for key in schema.keys where !groups.contains(key.group) { groups.append(key.group) }
        // Some schema sections live inside a named destination, not a generic
        // section link. Follow the surface's explicit route (never a fallback),
        // then check the same schema rows and sources inside that section alone.
        for group in groups {
            let inline = app.descendants(matching: .any)["settings-section-\(group)-detail"]
            let detail = inlineSections ? (inline.exists ? inline : nil)
                : openSettingsSectionIfServed(app, group, linkLabel: sectionDestinations[group])
            // One accessibility snapshot per destination preserves the same row,
            // badge and value checks without a remote AX round-trip per descendant.
            guard let snapshot = try? (detail ?? app).snapshot() else {
                XCTFail("could not read the \(name) \(group) accessibility tree")
                return coverage
            }
            let elements = descendants(of: snapshot)
            for key in schema.keys where key.group == group {
                var keyElements = elements
                var instances: XCUIElement?
                // Large qualified inventories (Mac permission floors) have their
                // own progressive sheet. A link is not a value/source row: enter
                // it and apply the same assertions to its concrete instances.
                let instancesLinkID = "settings-instances-\(key.id)-open"
                if elements.contains(where: { $0.identifier == instancesLinkID }) {
                    let link = hittableElement(app, identifier: instancesLinkID)
                    XCTAssertNotNil(link, "\(name) cannot reach the instances of \(key.id)")
                    link?.tap()
                    let detail = app.descendants(matching: .any)["settings-instances-\(key.id)-detail"]
                    XCTAssertTrue(detail.waitForExistence(timeout: 30), "the \(key.id) instances did not open")
                    guard let snapshot = try? detail.snapshot() else {
                        XCTFail("could not read the \(key.id) instances")
                        return coverage
                    }
                    instances = detail
                    keyElements = descendants(of: snapshot)
                }
                defer {
                    if let instances {
                        dismissTopSheet(app)
                        XCTAssertTrue(waitForNonExistence(instances, timeout: 15), "the \(key.id) instances must dismiss")
                    }
                }
                let token = settingRowToken(key.id)
                let rows = keyElements.filter { $0.identifier == token || $0.identifier.hasPrefix(token + "_") }
                let macInstancesOnly = key.qualifier == "key" || key.qualifier == "device"
                let served = !key.layers.isDisjoint(with: layers) && (!macInstancesOnly || isMacTarget)
                guard served else {
                    coverage.notServed += 1
                    if !allowsInheritedRows {
                        XCTAssertEqual(rows.count, 0, "\(name) must not show \(key.id): it is not served on this surface")
                    }
                    if rows.count == 0 { coverage.notServedAbsent += 1 }
                    continue
                }
                coverage.served += 1
                guard rows.count > 0 else {
                    XCTAssertTrue((key.qualifier == "project" || key.qualifier == "device") && isMacTarget,
                                  "\(name) serves \(key.id) but shows no row")
                    coverage.optionalAbsent += 1
                    continue
                }
                coverage.rowsPresent += 1
                let row = rows[0]
                let children = descendants(of: row)
                let labels = ((row.value as? String)?.components(separatedBy: " · ") ?? [])
                    + children.filter { $0.elementType == .staticText }.map(\.label)
                let allowedBadges = Set(key.layers.union(["builtin"]).compactMap { schema.layerLabels[$0] })
                // A fixed Chat value names its captured origin instead of also
                // showing a redundant Chat layer chip (settings-resolver fixedAt).
                let fixedOrigins = ["Home profile", "project default", "Mac default", "Tron default"]
                let provenance = Set(labels.filter { label in
                    allowedBadges.contains(label) || (key.layers.contains("chat") && (
                        label == "Chosen for this chat" || fixedOrigins.contains { origin in
                            let prefix = "From \(origin) at start: "
                            return label.hasPrefix(prefix) && label.count > prefix.count
                        }
                    ))
                })
                XCTAssertEqual(provenance.count, 1,
                               "\(name) row \(key.id) must show one precise source: \(labels)")
                coverage.layerBadgeChecked += 1
                // A switch's value is part of its button's label, so the value is read from every descendant.
                let described = children.map(\.label)
                    + children.filter { $0.elementType == .switch }.compactMap { $0.value as? String }
                XCTAssertTrue(described.contains { !$0.isEmpty && $0 != key.label && !allLayerLabels.contains($0) },
                              "\(name) row \(key.id) shows no value: \(described)")
                coverage.valueChecked += 1
            }
            if let detail, !inlineSections {
                if sectionDestinations[group] != nil {
                    keepScreenshot(app, name: "settings-surface-\(name)-\(group)")
                }
                dismissTopSheet(app)
                XCTAssertTrue(waitForNonExistence(detail, timeout: 15), "the \(group) sub-sheet must dismiss")
            }
        }
        return coverage
    }

    private func descendants(of snapshot: XCUIElementSnapshot) -> [XCUIElementSnapshot] {
        snapshot.children.flatMap { [$0] + descendants(of: $0) }
    }

    /// Opens a section's settings sub-sheet from the top-most surface, revealing
    /// its full-row link first (primary surfaces scroll; links may be above).
    @MainActor
    private func openSettingsSection(_ app: XCUIApplication, _ group: String, linkLabel: String? = nil) {
        XCTAssertNotNil(openSettingsSectionIfServed(app, group, linkLabel: linkLabel),
                        "the \(group) section has no settings link: \(app.debugDescription)")
    }

    @MainActor
    private func openSettingsSectionIfServed(_ app: XCUIApplication, _ group: String,
                                           linkLabel: String? = nil) -> XCUIElement? {
        let links = linkLabel.map { app.buttons.matching(NSPredicate(format: "label == %@", $0)) }
            ?? app.buttons.matching(identifier: "settings-section-\(group)-open")
        guard links.firstMatch.waitForExistence(timeout: 5) else { return nil }
        // The top-most surface's link is the last in tree order; a covered surface
        // beneath (Manage Session under the Project card) can hold the same link.
        // Scroll toward it: a blind downward swipe at the top of a medium sheet
        // would drag the sheet itself.
        let link = links.allElementsBoundByIndex.last!
        // Hittable is not enough: a row under the top-most navigation bar still
        // reports hittable while a tap there lands on the bar.
        func barBottom() -> CGFloat { app.navigationBars.allElementsBoundByIndex.last?.frame.maxY ?? 0 }
        for _ in 0..<24 where !(link.isHittable && link.frame.minY >= barBottom()) {
            if link.frame.minY < barBottom() + 40 { app.swipeDown() } else { app.swipeUp() }
        }
        // No reachable link means this surface serves the section nothing, which
        // the per-key checks then prove.
        guard link.isHittable, link.frame.minY >= barBottom() else { return nil }
        link.tap()
        let detail = app.descendants(matching: .any)["settings-section-\(group)-detail"]
        if let linkLabel {
            XCTAssertTrue(app.navigationBars.staticTexts[linkLabel].waitForExistence(timeout: 30),
                          "the \(linkLabel) destination did not open: \(app.debugDescription)")
            // Extensions embeds Sources below its inventory in a lazy stack;
            // materialize that section before taking its accessibility snapshot.
            for _ in 0..<24 where !detail.exists { app.swipeUp() }
        }
        XCTAssertTrue(detail.waitForExistence(timeout: 30), "the \(group) sub-sheet did not open: \(app.debugDescription)")
        return detail
    }

    /// Exact row identifiers: the key's own row, and each qualified instance
    /// (`<token>_<qualifiers>`). Child identifiers such as `-note` never match.
    @MainActor
    private func settingRows(_ scope: XCUIElement, key: String) -> XCUIElementQuery {
        let token = settingRowToken(key)
        return scope.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ OR identifier BEGINSWITH %@", token, token + "_"))
    }

    @MainActor
    private func settingRow(_ app: XCUIApplication, key: String) -> XCUIElement {
        app.descendants(matching: .any)[settingRowToken(key)]
    }

    /// Scrolls `element` down into view below the top-most sheet's navigation bar.
    /// A header row scrolled under that bar still reports itself hittable, but a
    /// tap there lands on the bar (seen in a gate run: "Review trust" at y 83-131
    /// under a bar spanning 88-142), so hittability alone is not enough.
    @MainActor
    private func revealBelowNavigationBar(_ app: XCUIApplication, _ element: XCUIElement) {
        for _ in 0..<40 {
            let bar = app.navigationBars.allElementsBoundByIndex.last
            if element.isHittable, element.frame.minY >= (bar?.frame.maxY ?? 0) { return }
            app.swipeDown()
        }
    }

    /// The switch row of `key` in the top-most presentation, revealed. A covered
    /// sheet beneath can hold a row with the same identifier (Manage Session under
    /// the Project card, where a Chat-layer key is editable too); covered rows are
    /// never hittable, so the first row whose switch is hittable is the top one.
    @MainActor
    private func topSwitchRow(_ app: XCUIApplication, key: String) -> XCUIElement {
        let rows = app.descendants(matching: .any).matching(identifier: settingRowToken(key))
        for _ in 0..<30 {
            for index in 0..<min(rows.count, 4) where rows.element(boundBy: index).switches.firstMatch.isHittable {
                return rows.element(boundBy: index)
            }
            app.swipeUp()
        }
        return rows.element(boundBy: max(rows.count - 1, 0))
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
    private func dismissTopSheet(_ app: XCUIApplication) {
        guard let done = revealedElement(app, where: NSPredicate(format: "label == %@", "Done"), timeout: 10) else {
            XCTFail("no hittable Done control to dismiss the presented sheet: \(app.debugDescription)")
            return
        }
        done.tap()
    }

    /// The Project card from Manage Session's shared Project settings link.
    @MainActor
    private func openProjectCard(_ app: XCUIApplication) {
        // The link can be below a newly opened medium sheet or above its current
        // scroll position. Swipe toward it; swiping down blindly dismisses the sheet.
        let link = app.buttons["project-settings-link"]
        XCTAssertTrue(link.waitForExistence(timeout: 30), "Manage Session has no Project settings link: \(app.debugDescription)")
        func barBottom() -> CGFloat { app.navigationBars.allElementsBoundByIndex.last?.frame.maxY ?? 0 }
        for _ in 0..<24 where !(link.isHittable && link.frame.minY >= barBottom()) {
            if link.frame.minY < barBottom() + 40 { app.swipeDown() } else { app.swipeUp() }
        }
        XCTAssertTrue(link.isHittable && link.frame.minY >= barBottom(),
                      "the Project settings link is not reachable: \(app.debugDescription)")
        link.tap()
        XCTAssertTrue(waitUntil(timeout: 30) { !app.buttons["project-settings-link"].isHittable },
                      "the Project card did not cover Manage Session: \(app.debugDescription)")
    }

    /// A switch row's value, read from the row's own switch.
    private func switchValue(_ row: XCUIElement) -> String? {
        row.switches.firstMatch.value.map { String(describing: $0) }
    }

    /// The row's sources (its accessibility value, one per " · ") and its
    /// messages, such as a refusal under the row.
    private func badgeLabels(_ row: XCUIElement) -> [String] {
        let sources = (row.value as? String).map { $0.components(separatedBy: " · ") } ?? []
        return sources + row.staticTexts.allElementsBoundByIndex.map { $0.label }
    }

    /// Toggles one row's switch through the shared control and waits for the
    /// Gateway's accepted state: the value flips and the badge names the layer.
    @MainActor
    private func toggleSetting(_ app: XCUIApplication, key: String, expectingBadge badge: String) -> (before: String?, after: String?) {
        XCTAssertTrue(settingRow(app, key: key).waitForExistence(timeout: 15), "\(key) has no row: \(app.debugDescription)")
        let row = topSwitchRow(app, key: key)
        let toggle = row.switches.firstMatch
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

    private func attachSettingsCoverage(_ coverage: [String: SurfaceCoverage], schema: SettingsSchemaInventory) {
        let attachment = XCTAttachment(string: coverageReport(coverage, schema: schema))
        attachment.name = "settings-surface-coverage.json"
        attachment.lifetime = .keepAlways
        add(attachment)
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
    private func launchApp(resettingState: Bool = true, additionalArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = (resettingState ? ["--tron-reset-ui-test-state"] : []) + [
            "-ApplePersistenceIgnoreState",
            "YES",
        ] + additionalArguments
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
    private func createSession(_ app: XCUIApplication, inWorkspace workspace: String,
                               beforeCreate: (() -> Void)? = nil) {
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
        beforeCreate?()
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

    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let absent = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [absent], timeout: timeout) == .completed
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

    /// The route's persistent recovery reason, matched by what it tells the user
    /// rather than by the control type that happens to render it.
    @MainActor
    private func recoveryStatus(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// Recovery belongs to the route's navigation chrome and is itself the
    /// Retry control: never a detached control floating over readable
    /// transcript rows (#878).
    @MainActor
    private func assertRecoveryInChrome(_ app: XCUIApplication, status: XCUIElement,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let bar = app.navigationBars.firstMatch
        XCTAssertTrue(bar.exists, "the chat route has no navigation bar", file: file, line: line)
        XCTAssertEqual(status.elementType, .button, "persistent recovery offers no Retry",
                       file: file, line: line)
        XCTAssertTrue(status.isHittable, "persistent recovery Retry is not reachable", file: file, line: line)
        XCTAssertTrue(bar.frame.contains(status.frame),
                      "recovery \(status.frame) left the navigation chrome \(bar.frame)",
                      file: file, line: line)
    }

    /// The rendered transcript band between the navigation chrome and the
    /// composer, excluding the trailing scroll indicator.
    @MainActor
    private func transcriptRows(_ app: XCUIApplication) -> CGImage? {
        let screenshot = app.screenshot().image
        let scale = screenshot.scale
        return screenshot.cgImage?.cropping(to: CGRect(x: 30 * scale, y: 150 * scale,
                                                       width: 330 * scale, height: 260 * scale))
    }

    /// The fraction of pixels whose color moved by more than a rounding step.
    private func changedPixelFraction(_ before: CGImage?, _ after: CGImage?) -> Double {
        guard let before, let after, before.width == after.width, before.height == after.height else { return 1 }
        func pixels(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return bytes
        }
        let a = pixels(before), b = pixels(after)
        var changed = 0
        for index in stride(from: 0, to: a.count, by: 4)
        where (0..<3).contains(where: { abs(Int(a[index + $0]) - Int(b[index + $0])) > 8 }) {
            changed += 1
        }
        return Double(changed) / Double(a.count / 4)
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
        let group: String
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
            guard let id = row["id"] as? String, let label = row["label"] as? String, let group = row["group"] as? String,
                  let layers = row["layers"] as? [String] else { throw SettingsInventoryError.malformed }
            return Key(id: id, label: label, group: group, layers: Set(layers), qualifier: row["qualifier"] as? String)
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
