import Foundation
import UIKit
import XCTest

final class RealGatewayPairAndChatUITests: XCTestCase {
    private let prompt = "Fixture journey: verify the real Gateway round trip\n"
        + (1...18).map { "Continuity anchor line \($0): keep this conversation visible." }.joined(separator: "\n")
    private let replyPrefix = "Streaming response starts now"
    private let replyCompletion = "Detached response complete"

    override func tearDown() {
        MainActor.assumeIsolated(RealGatewayUIHost.resetHostedAppState)
        super.tearDown()
    }

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
        let send = app.buttons["Send message"]
        XCTAssertTrue(send.waitForExistence(timeout: 60), "the send control never appeared: \(app.debugDescription)")
        XCTAssertTrue(waitForEnabled(send, timeout: 60), "the composer never accepted the prompt: \(app.debugDescription)")
        send.tap()

        let sent = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", prompt)).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 60), "the sent prompt is not in the transcript: \(app.debugDescription)")

        var observations: [String] = []
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            let completed = assistantReply(app, containing: replyPrefix)
            let element = completed.exists ? completed
                : app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", replyPrefix)).firstMatch
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

        let sameRouteReply = assistantReply(app, containing: replyCompletion)
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
        app.typeText(" Still editing.")
        unsentDraft += " Still editing."
        XCTAssertEqual(composer.value as? String, unsentDraft)
        try setProxyMode(fixture, mode: "pass")
        XCTAssertTrue(sameRouteReply.waitForExistence(timeout: 60))
        XCTAssertTrue(waitForEnabled(send, timeout: 60), "replacement authority did not become ready")
        XCTAssertFalse(waitingStatus.exists, "the replacement connection left its recovery status behind")

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

        let replyFrameBeforeForeground = sameRouteReply.frame
        try setProxyMode(fixture, mode: "hold-hello")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(waitForBackground(app, timeout: 60))
        let activationRequestedAt = Date()
        app.activate()
        XCTAssertTrue(waitForForeground(app, timeout: 90))
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

        let transcriptScroll = app.scrollViews.containing(
            NSPredicate(format: "label CONTAINS %@", "real Gateway round trip")
        ).firstMatch
        XCTAssertTrue(transcriptScroll.exists)
        let readerStart = transcriptScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let readerEnd = transcriptScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.48))
        readerStart.press(forDuration: 0.1, thenDragTo: readerEnd)
        readerStart.press(forDuration: 0.1, thenDragTo: readerEnd)
        keepScreenshot(app, name: "393-simulator-reader-detaches")
        XCTAssertTrue(app.buttons["Catch up"].waitForExistence(timeout: 10),
                      "the reader did not leave the pinned tail: \(app.debugDescription)")
        XCTAssertTrue(sent.isHittable)
        let anchorFrame = sent.frame
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
            sent.waitForExistence(timeout: 90),
            "the prompt left the transcript across background/foreground: \(app.debugDescription)"
        )
        XCTAssertTrue(
            assistantReply(app, containing: replyCompletion)
                .waitForExistence(timeout: 90),
            "the reply left the transcript across background/foreground: \(app.debugDescription)"
        )
        keepScreenshot(app, name: "424-real-ui-conversation-after-background")

        app.buttons["Back"].tap()
        let sessionRow = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "session-row-")
        ).firstMatch
        XCTAssertTrue(waitForHittable(sessionRow, timeout: 60), app.debugDescription)
        try setProxyMode(fixture, mode: "blackhole")
        defer { try? setProxyMode(fixture, mode: "pass") }
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
        try setProxyMode(fixture, mode: "pass")
        let retainedReply = assistantReply(app, containing: replyCompletion)
        XCTAssertTrue(retainedReply.waitForExistence(timeout: 60),
                      "the waiting route did not resume without another tap: \(app.debugDescription)")
        XCTAssertFalse(app.staticTexts["Waiting for connection"].exists)
        keepScreenshot(app, name: "393-simulator-reconnected-without-retry")

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
        let largeReply = assistantReply(largeText, containing: replyCompletion)
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

        let composer = firstRun.textViews["Message input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 60), firstRun.debugDescription)
        composer.tap()
        composer.typeText("Start the conversation.")
        let send = firstRun.buttons["Send message"]
        XCTAssertTrue(waitForEnabled(send, timeout: 60), "the composer never accepted the prompt: \(firstRun.debugDescription)")
        send.tap()
        XCTAssertTrue(
            assistantReply(firstRun, containing: replyCompletion)
                .waitForExistence(timeout: 120),
            "the first turn never completed: \(firstRun.debugDescription)"
        )

        composer.tap()
        composer.typeText("Fixture ask journey: ask me where to deploy.")
        XCTAssertTrue(waitForEnabled(send, timeout: 60), "the composer never accepted the ask prompt: \(firstRun.debugDescription)")
        send.tap()
        XCTAssertTrue(firstRun.buttons["Submit all answers"].waitForExistence(timeout: 90),
                      "the running agent's ask_user form never appeared: \(firstRun.debugDescription)")

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
        let reply = assistantReply(app, containing: "Ask journey answered")
        XCTAssertTrue(reply.waitForExistence(timeout: 90),
                      "the agent's reply to the answer never reached the transcript: \(app.debugDescription)")
        XCTAssertTrue(waitForHittable(reply, timeout: 30),
                      "the transcript left the tail after the answer: \(app.debugDescription)")
        keepScreenshot(app, name: "935-answered-ask-user-transcript-mounted")
        XCTAssertEqual(lifecycle.value as? String, openedLifecycle,
                       "answering the form reopened or re-revealed the mounted transcript")
        XCTAssertTrue(prompt.exists, "answering the form dropped the earlier transcript rows")
        XCTAssertFalse(app.otherElements["Opening conversation"].exists)
    }

    @MainActor
    func testCompletedAskUserColdReplayRetainsSelectedAnswers() throws {
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
        composer.typeText("Fixture ask journey: ask me where to deploy, then verify historical sheet replay.")
        let send = app.buttons["Send message"]
        XCTAssertTrue(waitForEnabled(send, timeout: 60), app.debugDescription)
        send.tap()
        let submit = app.buttons["Submit all answers"]
        XCTAssertTrue(waitForHittable(submit, timeout: 90), app.debugDescription)
        app.buttons["Staging"].tap()
        app.buttons["Canary"].tap()
        XCTAssertTrue(waitForEnabled(submit, timeout: 30), app.debugDescription)
        submit.tap()
        XCTAssertTrue(waitForAbsence(submit, timeout: 60), app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Ask journey answered"))
            .firstMatch.waitForExistence(timeout: 90), app.debugDescription)
        app.buttons["Back"].tap()
        let originalRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "session-row-")).firstMatch
        XCTAssertTrue(waitForHittable(originalRow, timeout: 60), app.debugDescription)
        let originalRowID = originalRow.identifier
        originalRow.tap()

        app.buttons["Back"].tap()
        XCTAssertTrue(waitForHittable(app.buttons[originalRowID], timeout: 60), app.debugDescription)
        createSession(app, inWorkspace: fixture.workspace)
        let otherComposer = app.textViews["Message input"]
        XCTAssertTrue(otherComposer.waitForExistence(timeout: 60), app.debugDescription)
        otherComposer.tap()
        otherComposer.typeText("Persist a second conversation for the cold replay control.")
        let otherSend = app.buttons["Send message"]
        XCTAssertTrue(waitForEnabled(otherSend, timeout: 60), app.debugDescription)
        otherSend.tap()
        XCTAssertTrue(assistantReply(app, containing: replyCompletion).waitForExistence(timeout: 120), app.debugDescription)
        app.buttons["Back"].tap()
        let original = app.buttons[originalRowID]
        XCTAssertTrue(waitForHittable(original, timeout: 60), app.debugDescription)
        original.tap()
        let ask = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Ask user, Completed")).firstMatch
        XCTAssertTrue(waitForHittable(ask, timeout: 60), app.debugDescription)
        ask.tap()
        XCTAssertTrue(app.staticTexts["Review answers"].waitForExistence(timeout: 15),
                      "Cold canonical replay opened generic details instead of the completed question: \(app.debugDescription)")
        for (label, value) in [("Staging", "Selected"), ("Production", "Not selected"), ("Canary", "Selected")] {
            let option = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ AND value == %@", label, value)).firstMatch
            XCTAssertTrue(option.exists, "\(label) must be \(value) in the read-only replay: \(app.debugDescription)")
        }
        XCTAssertFalse(app.buttons["Submit all answers"].exists)
        XCTAssertFalse(app.buttons["Staging"].exists, "Completed answers are not mutable controls")
        keepScreenshot(app, name: "1302-cold-canonical-ask-user-selected-answers")
        dismissTopSheet(app)
        let readChip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Read file, Completed,")).firstMatch
        for index in 0..<2 {
            XCTAssertTrue(waitForHittable(readChip, timeout: 15), app.debugDescription)
            readChip.tap()
            let info = app.buttons["Technical details"].firstMatch
            XCTAssertTrue(info.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Keep the boundary fixture honest.")).firstMatch.exists,
                          "The file renderer must retain this call's canonical result")
            let done = app.buttons.matching(NSPredicate(format: "label == 'Done'")).allElementsBoundByIndex.last(where: \.isHittable)!
            XCTAssertGreaterThan(done.frame.minY, app.windows.firstMatch.frame.height * 0.35,
                                 "A cold-replayed tool starts medium on every fresh presentation")
            keepScreenshot(app, name: "1309-cold-read-\(index)-medium")
            let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: app.windows.firstMatch.frame.midX, dy: done.frame.minY - 12))
                .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: app.windows.firstMatch.frame.midX, dy: 20)))
            let expanded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in done.frame.minY < 120 }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 5), .completed)
            if index == 0 {
                info.tap()
                let request = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Inspect Request JSON,'")).firstMatch
                XCTAssertTrue(request.waitForExistence(timeout: 5))
                request.tap()
                XCTAssertTrue(app.staticTexts["Request JSON"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS 'AGENTS.md'")).firstMatch.waitForExistence(timeout: 5),
                              "The native JSON reader must expose this call's canonical request")
                dismissTopSheet(app)
                dismissTopSheet(app)
                XCTAssertTrue(info.waitForExistence(timeout: 5))
                XCTAssertLessThan(done.frame.minY, 120, "Info/back must not reset the parent's chosen detent")
            }
            dismissTopSheet(app)
            if index == 0 {
                ask.tap()
                XCTAssertTrue(app.staticTexts["Review answers"].waitForExistence(timeout: 10))
                XCTAssertFalse(app.buttons["Submit all answers"].exists)
                dismissTopSheet(app)
            }
        }

        let agent = URL(fileURLWithPath: try XCTUnwrap(fixture.agentDirectory))
        let log = try String(contentsOf: fixture.tronHome.appending(path: "logs/gateway.jsonl"), encoding: .utf8)
        let events = try log.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        let evictionIndex = try XCTUnwrap(events.firstIndex { $0["event"] as? String == "runtime.evicted" && $0["reason"] as? String == "capacity" })
        let sessionID = try XCTUnwrap(events[evictionIndex]["sessionId"] as? String)
        XCTAssertTrue(originalRowID.hasSuffix(sessionID),
                      "The reopened UI row \(originalRowID) must be the exact canonically evicted session \(sessionID)")
        XCTAssertTrue(events.dropFirst(evictionIndex + 1).contains { $0["event"] as? String == "runtime.loaded" && $0["sessionId"] as? String == sessionID },
                      "The first session must be cold-loaded after its eviction")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: agent.appending(path: "sessions"), includingPropertiesForKeys: nil))
        var durableAnswer: [String: Any]?
        while let file = files.nextObject() as? URL {
            guard file.pathExtension == "jsonl" else { continue }
            let entries = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
                .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
            guard entries.first?["id"] as? String == sessionID else { continue }
            durableAnswer = entries.compactMap { $0["message"] as? [String: Any] }
                .first { $0["role"] as? String == "toolResult" && $0["toolCallId"] as? String == "e2e-ask-1" }
        }
        let result = try XCTUnwrap(durableAnswer)
        let details = try XCTUnwrap(result["details"] as? [String: Any])
        let answers = try XCTUnwrap(details["answers"] as? [String: [String: Any]])
        XCTAssertEqual(answers["Where should the fixture deploy?"]?["selected"] as? [String], ["Staging", "Canary"])
        XCTAssertNil(result["extensionOrigin"], "Canonical answers must not depend on ephemeral execution metadata")
        let evidence = XCTAttachment(data: try JSONSerialization.data(withJSONObject: [
            "evicted": events[evictionIndex], "canonicalToolResult": result,
            "reopenedRowID": originalRowID, "reviewedSelections": ["Staging", "Canary"],
        ], options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        evidence.name = "1302-cold-ask-user-replay"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    @MainActor
    func testMacReplacementRowAndProgressFollowTheJournal() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let store = fixture.tronHome.deletingLastPathComponent().appending(path: ".tron-maintenance/replace")
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

        try writeJournal(state: "running", current: "swap-app", done: 5)
        XCTAssertTrue(app.staticTexts["Step 6 of 9"].waitForExistence(timeout: 15), app.debugDescription)
        try writeJournal(state: "succeeded", current: nil, done: 9)
        XCTAssertTrue(app.staticTexts["Replaced"].waitForExistence(timeout: 15), app.debugDescription)
        keepScreenshot(app, name: "984-progress-succeeded")
        dismissTopSheet(app)

        let replace = app.buttons["Replace Mac app"]
        XCTAssertTrue(replace.waitForExistence(timeout: 15), app.debugDescription)
        keepScreenshot(app, name: "984-connections-row-settled")
    }

    @MainActor
    func testImageOnlySteerLeavesTheQueueOnceDelivered() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let firstRun = launchApp()
        open(fixture.invitationLink())
        completeFirstRunSetup(firstRun, inWorkspace: fixture.workspace)
        XCTAssertTrue(waitForHittable(firstRun.buttons["dashboard.menu"], timeout: 90), firstRun.debugDescription)
        createSession(firstRun, inWorkspace: fixture.workspace)

        let composer = firstRun.textViews["Message input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 60), firstRun.debugDescription)
        composer.tap()
        composer.typeText("Start the conversation.")
        let send = firstRun.buttons["Send message"]
        XCTAssertTrue(waitForEnabled(send, timeout: 60), firstRun.debugDescription)
        send.tap()
        XCTAssertTrue(
            assistantReply(firstRun, containing: replyCompletion)
                .waitForExistence(timeout: 120),
            "the first turn never completed: \(firstRun.debugDescription)"
        )

        composer.tap()
        composer.typeText("Fixture steer journey: wait for my photo.")
        XCTAssertTrue(waitForEnabled(send, timeout: 60), firstRun.debugDescription)
        send.tap()
        XCTAssertTrue(firstRun.buttons["Stop Tron"].waitForExistence(timeout: 60),
                      "the held turn never started: \(firstRun.debugDescription)")

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

        let queuedSteer = firstRun.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "After the current turn")
        ).firstMatch
        XCTAssertTrue(queuedSteer.waitForExistence(timeout: 30),
                      "the photo was not queued as a steer: \(firstRun.debugDescription)")
        keepScreenshot(firstRun, name: "974-image-only-steer-queued")
        let delivered = assistantReply(firstRun, containing: "Steer journey saw the photo")
        XCTAssertTrue(delivered.waitForExistence(timeout: 120),
                      "the model never received the steered photo: \(firstRun.debugDescription)")
        XCTAssertTrue(waitForAbsence(queuedSteer, timeout: 30),
                      "the delivered photo is still shown as a queued steer: \(firstRun.debugDescription)")
        keepScreenshot(firstRun, name: "974-image-only-steer-delivered")

        firstRun.terminate()
        let app = launchApp(resettingState: false)
        defer { app.terminate() }
        let sessionRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "session-row-")).firstMatch
        XCTAssertTrue(waitForHittable(sessionRow, timeout: 90), app.debugDescription)
        sessionRow.tap()
        let reopenedReply = assistantReply(app, containing: "Steer journey saw the photo")
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
        let wrongCode = String(repeating: "0", count: fixture.code.count)
        let app = launchApp()
        defer { app.terminate() }
        open(fixture.invitationLink(code: wrongCode))
        let refusal = firstNoticeLabel(app, timeout: 60)
        XCTAssertEqual(
            refusal, "Pairing code is invalid",
            "the rejected invitation must report the Gateway's own failure"
        )
        keepScreenshot(app, name: "424-real-ui-wrong-pairing-code")

        open(fixture.invitationLink())
        XCTAssertTrue(
            app.buttons["Choose workspace"].waitForExistence(timeout: 90),
            "the fixture's own code must pair through the same link: \(app.debugDescription)"
        )
        keepScreenshot(app, name: "424-real-ui-accepted-code-pairs")
    }

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
        composer.typeText("CODEMODE-ASK-USER-JOURNEY: ask from inside codemode")
        let send = app.buttons["Send message"]
        XCTAssertTrue(waitForEnabled(send, timeout: 60), app.debugDescription)
        send.tap()

        let submit = app.buttons["Submit all answers"]
        XCTAssertTrue(submit.waitForExistence(timeout: 90), "the codemode question was never presented: \(app.debugDescription)")
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: window.frame.midX, dy: submit.frame.midY))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(waitForNonExistence(submit, timeout: 10), app.debugDescription)
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "Codemode,", "Builtin Codemode")).firstMatch
        XCTAssertTrue(waitForHittable(row, timeout: 30), "the running codemode row is not tappable: \(app.debugDescription)")
        row.tap()
        XCTAssertTrue(submit.waitForExistence(timeout: 10),
                      "tapping the running codemode row did not reopen its pending question: \(app.debugDescription)")
        XCTAssertTrue(app.buttons["Approve it"].exists, app.debugDescription)
        keepScreenshot(app, name: "929-codemode-ask-user-opened-from-row")
        app.buttons["Approve it"].tap()
        submit.tap()
        let answered = assistantReply(app, containing: "Codemode question answered")
        XCTAssertTrue(answered.waitForExistence(timeout: 90), "the answer never reached the codemode script: \(app.debugDescription)")
        XCTAssertTrue(answered.label.contains("Approve it"), "the codemode script read another answer: \(answered.label)")
        keepScreenshot(app, name: "929-codemode-ask-user-answered")
    }

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

        let gear = app.navigationBars.buttons["Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 30), app.debugDescription)
        gear.tap()
        XCTAssertTrue(app.buttons["settings-done"].waitForExistence(timeout: 30), app.debugDescription)
        guard let macTerminal = hittableElement(app, identifier: "settings-link-Mac Terminal", timeout: 30) else {
            return XCTFail("no Mac Terminal row: \(app.debugDescription)")
        }
        macTerminal.tap()
        let terminalTitle = app.descendants(matching: .any)["terminal-sheet-title"].firstMatch
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
        dismissTopSheet(app)
        XCTAssertTrue(app.buttons["settings-done"].waitForExistence(timeout: 10), "closing Mac Terminal lost Settings: \(app.debugDescription)")

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
        let grabber = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
        grabber.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(waitForAbsence(name, timeout: 10), "Add Server did not close: \(app.debugDescription)")
        dismissTopSheet(app)
        dismissTopSheet(app)

        XCTAssertTrue(composer.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertEqual(composer.value as? String, draft, "the unsent composer draft was lost")
    }

    @MainActor
    func returnFromAnotherApp(_ app: XCUIApplication) {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.activate()
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 20), "Safari did not become foreground")
        XCTAssertTrue(waitForBackground(app, timeout: 30), "Tron never reached the background")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), "Tron did not return to the foreground")
        safari.terminate()
    }

    @MainActor
    func forceReconnect(_ fixture: RealGatewayUIFixture) throws {
        try setProxyMode(fixture, mode: "blackhole")
        Thread.sleep(forTimeInterval: 25)
        try setProxyMode(fixture, mode: "pass")
        Thread.sleep(forTimeInterval: 10)
    }

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
    private func visibleText(_ element: XCUIElement) -> String {
        element.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: "|")
    }

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
            _ = app.buttons.matching(identifier: identifier).firstMatch.waitForExistence(timeout: 30)
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

        let ring = app.buttons["session-context-button"]
        XCTAssertTrue(ring.waitForExistence(timeout: 60), app.debugDescription)
        ring.tap()
        XCTAssertTrue(app.staticTexts["Manage Session"].waitForExistence(timeout: 30), app.debugDescription)
        burst("manage-session")
        for _ in 0..<4 { app.swipeUp() }
        burst("manage-session-rows")
        openSheet("chat-settings-link", "session-settings")
        let settings = app.descendants(matching: .any)["session-settings-content"]
        XCTAssertFalse(settings.buttons["Switch Model"].exists)
        openSheet("settings-section-tools-open", "session-tools", section: "tools")
        XCTAssertFalse(app.buttons["settings-section-advanced-open"].exists, "An empty section has no destination")
        dismissTopSheet(app)
        dismissTopSheet(app)
        dismissTopSheet(app)

        let gear = app.navigationBars.buttons["Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 30), app.debugDescription)
        gear.tap()
        XCTAssertTrue(app.buttons["settings-done"].waitForExistence(timeout: 30), app.debugDescription)
        burst("settings")
        openSheet("settings-link-Agent Behavior", "global-agent-behavior", section: "model")
        XCTAssertTrue(app.descendants(matching: .any)["settings-section-run-detail"].waitForExistence(timeout: 30))
        dismissTopSheet(app)
        openSheet("settings-section-tools-open", "global-tools", section: "tools"); dismissTopSheet(app)
        for (title, name) in [("MCP Servers", "mcp"), ("Extensions", "extensions"), ("Hooks", "hooks"),
                              ("Model Providers", "providers"), ("Setup", "setup")] {
            openSheet("settings-link-\(title)", name); dismissTopSheet(app)
        }
    }

    @MainActor
    func testSettingsSourcesTextDoneAndRoutes() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        try addMcpServerOutsideTron(fixture.agentDirectory, name: "docs-server")
        let app = launchApp()
        defer { app.terminate() }
        open(fixture.invitationLink())
        completeFirstRunSetup(app, inWorkspace: fixture.workspace)
        XCTAssertTrue(waitForHittable(app.buttons["dashboard.menu"], timeout: 90), app.debugDescription)
        createSession(app, inWorkspace: fixture.workspace) {
            let project = app.buttons["project-settings-link"]
            XCTAssertTrue(project.waitForExistence(timeout: 30), app.debugDescription)
            let projectName = URL(fileURLWithPath: fixture.workspace).lastPathComponent
            let projectValue = project.value as? String ?? ""
            XCTAssertTrue(projectValue.contains(projectName),
                          "New Session must retain its selected repository identity: \(project.label) / \(projectValue)")
            let modelCard = app.buttons["new-session-card.Model"]
            for _ in 0..<12 where !modelCard.isHittable || modelCard.frame.maxY > app.frame.maxY - 40 { app.swipeUp() }
            XCTAssertTrue(modelCard.exists, app.debugDescription)
            XCTAssertFalse(provenanceWords.contains { modelCard.staticTexts[$0].exists },
                           "New Session must not reintroduce provenance pills")
            XCTAssertTrue(modelCard.label.localizedCaseInsensitiveContains("e2e model"),
                          "The fixture Gateway's configured model must remain visible: \(modelCard.label)")
            self.keepScreenshot(app, name: "939-new-session")
        }

        let gear = app.navigationBars.buttons["Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 30), app.debugDescription)
        gear.tap()
        XCTAssertTrue(app.buttons["settings-done"].waitForExistence(timeout: 30), app.debugDescription)
        for (name, marker) in [("Appearance", app.textFields["Chats per project"]),
                               ("Setup", app.switches["Run Swift files"])] {
            let link = app.buttons["settings-link-" + name]
            revealBelowNavigationBar(app, link)
            link.tap()
            XCTAssertTrue(app.navigationBars.staticTexts[name].waitForExistence(timeout: 30), app.debugDescription)
            XCTAssertTrue(marker.waitForExistence(timeout: 30), app.debugDescription)
            revealBelowNavigationBar(app, marker)
            XCTAssertTrue(marker.isHittable, app.debugDescription)
            dismissTopSheet(app)
            XCTAssertTrue(app.buttons["settings-done"].exists)
        }
        keepScreenshot(app, name: "1325-global-settings-live-routes")

        let mcpLink = app.buttons["settings-link-MCP Servers"]
        for _ in 0..<12 where !mcpLink.isHittable { app.swipeUp() }
        mcpLink.tap()
        let server = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "docs-server")).firstMatch
        XCTAssertTrue(server.waitForExistence(timeout: 60), app.debugDescription)
        keepScreenshot(app, name: "939-mcp-servers")
        dismissTopSheet(app)

        let extensionsLink = app.buttons["settings-link-Extensions"]
        for _ in 0..<12 where !extensionsLink.isHittable { app.swipeUp() }
        extensionsLink.tap()
        for (key, name) in [("sources.npmCommand", "npm"), ("sources.extensions", "search-path")] {
            guard let row = hittableElement(app, identifier: settingRowToken(key), timeout: 60) else {
                XCTFail("Extensions has no \(key) row: \(app.debugDescription)"); return
            }
            (row.buttons.allElementsBoundByIndex.last ?? row).tap()
            let value = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Add value")).textFields.firstMatch
            XCTAssertTrue(value.waitForExistence(timeout: 15), "the \(key) sheet has no add-value field: \(app.debugDescription)")
            XCTAssertNotEqual(value.placeholderValue ?? "", "Value", "the placeholder must be a real example")
            XCTAssertFalse((value.placeholderValue ?? "").isEmpty, "the add-value field shows the schema's example")
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "For example:")).firstMatch.exists,
                          "the add-value row says what to enter: \(app.debugDescription)")
            if key == "sources.npmCommand" {
                XCTAssertEqual(value.placeholderValue, "pnpm")
                value.tap()
                XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "The real add-value field must acquire keyboard focus")
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
        dismissTopSheet(app)

        for (title, marker, name) in [("Connections", "Paired Macs", "connections"), ("Push Notifications", "Input needed", "push")] {
            let link = app.buttons["settings-link-\(title)"]
            revealBelowNavigationBar(app, link)
            link.tap()
            func labelled(_ text: String) -> XCUIElement {
                app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", text)).firstMatch
            }
            XCTAssertTrue(labelled(marker).waitForExistence(timeout: 30), "\(title) did not open: \(app.debugDescription)")
            if title == "Connections" {
                XCTAssertFalse(labelled("Input needed").exists, "push alerts moved to their own sheet")
                assertToolbarTint(app, title: "Connections")
                let device = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Details for ' AND label CONTAINS ' on '")).firstMatch
                XCTAssertTrue(device.waitForExistence(timeout: 30), app.debugDescription)
                let label = device.label.dropFirst("Details for ".count)
                let deviceName = String(label[..<(label.range(of: " on ", options: .backwards)?.lowerBound ?? label.endIndex)])
                device.tap()
                XCTAssertTrue(app.buttons["device-rename"].waitForExistence(timeout: 30), app.debugDescription)
                assertToolbarTint(app, title: deviceName)
                keepScreenshot(app, name: "963-device-detail")
                dismissTopSheet(app)
                let server = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Details for ' AND NOT label CONTAINS ' on '")).firstMatch
                XCTAssertTrue(server.waitForExistence(timeout: 30), app.debugDescription)
                server.tap()
                let service = app.descendants(matching: .any)[settingRowToken("permissions.macTerminalServer")]
                revealBelowNavigationBar(app, service)
                XCTAssertTrue(service.waitForExistence(timeout: 30), "This Mac's page must show the SSH service row: \(app.debugDescription)")
                XCTAssertTrue(service.staticTexts["Private Mac SSH service"].exists, app.debugDescription)
                XCTAssertEqual(service.switches.firstMatch.value as? String, "0", "The fixture's private SSH service starts stopped")
                keepScreenshot(app, name: "2208-mac-terminal-service-row")
                dismissTopSheet(app)
            }
            keepScreenshot(app, name: "939-\(name)")
            dismissTopSheet(app)
        }
    }

    @MainActor
    func testRoutineEditorsDisappearAndExplicitGlobalValueResets() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let agentDirectory = try XCTUnwrap(fixture.agentDirectory)
        let file = URL(fileURLWithPath: agentDirectory).appendingPathComponent("settings.json")
        var document = try globalSettingsDocument(fixture.agentDirectory)
        document["retry"] = ["maxRetries": 0]
        try JSONSerialization.data(withJSONObject: document).write(to: file)
        let app = launchApp()
        defer { app.terminate() }
        open(fixture.invitationLink())
        completeFirstRunSetup(app, inWorkspace: fixture.workspace)
        XCTAssertTrue(waitForHittable(app.buttons["dashboard.menu"], timeout: 90), app.debugDescription)
        createSession(app, inWorkspace: fixture.workspace)
        let gear = app.navigationBars.buttons["Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 30)); gear.tap()
        openAgentBehavior(app)
        XCTAssertFalse(settingRow(app, key: "context.compaction.enabled").exists,
                       "Inherited routine compaction still has no editor in the consolidated sheet")
        let row = settingRow(app, key: "run.retry.maxRetries")
        revealBelowNavigationBar(app, row)
        XCTAssertTrue(row.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(row.staticTexts["0 retries"].exists, row.debugDescription)
        let reset = app.buttons["settings-row-run.retry.maxRetries-reset"]
        XCTAssertTrue(reset.isHittable, row.debugDescription)
        XCTAssertEqual(row.buttons.count, 1, "An explicit routine value offers only Reset, never an editor")
        keepScreenshot(app, name: "1975-zero-override-reset-only")
        reset.tap()
        XCTAssertTrue(waitUntil(timeout: 30) {
            let retry = (try? self.globalSettingsDocument(fixture.agentDirectory))?["retry"] as? [String: Any]
            return retry?["maxRetries"] == nil
        }, "Reset removes the explicit value through the real settings change path")
        XCTAssertTrue(waitForNonExistence(row, timeout: 30), app.debugDescription)
        XCTAssertTrue(app.buttons["HTTP proxy"].waitForExistence(timeout: 15),
                      "Connection keeps its safety proxy editor: \(app.debugDescription)")
        keepScreenshot(app, name: "1975-inherited-routine-row-gone")
    }

    @MainActor
    func testSessionSettingsOmitsInheritedRoutineEditors() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let app = launchApp()
        defer { app.terminate() }
        open(fixture.invitationLink())
        completeFirstRunSetup(app, inWorkspace: fixture.workspace)
        XCTAssertTrue(waitForHittable(app.buttons["dashboard.menu"], timeout: 90), app.debugDescription)
        createSession(app, inWorkspace: fixture.workspace)

        let manageSessionButton = app.buttons["session-context-button"]
        XCTAssertTrue(manageSessionButton.waitForExistence(timeout: 60), app.debugDescription)
        XCTAssertTrue(manageSessionButton.label.contains("Manage Session"), manageSessionButton.debugDescription)
        manageSessionButton.tap()
        XCTAssertTrue(app.staticTexts["Manage Session"].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.buttons["chat-settings-link"].waitForExistence(timeout: 15),
                      "Manage Session must link to Session Settings: \(app.debugDescription)")
        XCTAssertFalse(app.buttons["project-settings-link"].exists,
                       "Project Settings is a section of Session Settings, not a Manage Session row (#1655)")
        app.buttons["chat-settings-link"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Session Settings"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["session-project-settings"].waitForExistence(timeout: 15))
        for id in ["settings-section-context-open", "settings-section-run-open"] {
            XCTAssertFalse(app.buttons[id].exists,
                           "Session Settings offers recovery for explicit overrides, not inherited routine editors")
        }
        XCTAssertFalse(settingRow(app, key: "run.retry.enabled").exists)
        keepScreenshot(app, name: "1975-session-inherited-routine-editors-absent")
        dismissTopSheet(app)
        dismissTopSheet(app)
        manageSessionButton.tap()
        XCTAssertTrue(app.buttons["chat-settings-link"].waitForExistence(timeout: 15))
        app.buttons["chat-settings-link"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Session Settings"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["settings-section-run-open"].exists, "Reopening cannot manufacture an override")
    }

    @MainActor
    func testProjectSettingsExposeReadOnlyOverrides() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let projectFile = URL(fileURLWithPath: fixture.workspace).appendingPathComponent(".pi/settings.json")
        try FileManager.default.createDirectory(at: projectFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let projectBytes = Data(#"{"compaction":{"enabled":false}}"#.utf8)
        try projectBytes.write(to: projectFile)
        let app = launchApp()
        defer { app.terminate() }
        open(fixture.invitationLink())
        completeFirstRunSetup(app, inWorkspace: fixture.workspace)
        XCTAssertTrue(waitForHittable(app.buttons["dashboard.menu"], timeout: 90), app.debugDescription)
        createSession(app, inWorkspace: fixture.workspace)
        let manage = app.buttons["session-context-button"]
        XCTAssertTrue(manage.waitForExistence(timeout: 60)); manage.tap()
        openProjectCard(app)
        let none = app.staticTexts["No repository overrides"]
        let row = settingRow(app, key: "context.compaction.enabled")
        XCTAssertTrue(none.waitForExistence(timeout: 30), "An untrusted override is not applied: \(app.debugDescription)")
        XCTAssertFalse(row.exists, "An unapplied repository override has no row or mutation route")
        XCTAssertEqual(try Data(contentsOf: projectFile), projectBytes, "Inspection must not change repository bytes")
        dismissTopSheet(app)
        openProjectCard(app)
        XCTAssertTrue(none.waitForExistence(timeout: 30) && !row.exists, "Reopening reads the same repository state")
        XCTAssertEqual(try Data(contentsOf: projectFile), projectBytes)
        keepScreenshot(app, name: "1308-project-readonly-source")
    }

    @MainActor
    func testGlobalSettingsServeExposedEditorsAndEditAtGlobalScope() throws {
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

        let globalSettingsGear = app.navigationBars.buttons["Settings"]
        func openGlobalSettings() {
            XCTAssertTrue(globalSettingsGear.waitForExistence(timeout: 30), app.debugDescription)
            globalSettingsGear.tap()
            XCTAssertTrue(app.navigationBars.staticTexts["Global Settings"].waitForExistence(timeout: 30), app.debugDescription)
        }
        openGlobalSettings(); XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "More Settings")).count, 0,
                                             "Global embeds its former More Settings groups in Agent Behavior")
        coverage["settings"] = assertSettingsSurface(app, name: "settings", layers: ["global"], schema: schema, sectionDestinations: [
            "model": "Agent Behavior", "workers": "Agent Behavior", "context": "Agent Behavior", "run": "Agent Behavior",
            "sources": "Extensions", "setup": "Setup"])
        openSettingsSection(app, "tools")
        let codeMode = app.buttons["Other tools with codemode"]
        revealBelowNavigationBar(app, codeMode)
        codeMode.tap()
        let only = app.buttons["settings-option-Codemode only"]
        XCTAssertTrue(only.waitForExistence(timeout: 5), app.debugDescription)
        keepScreenshot(app, name: "settings-surface-code-mode-choice")
        only.tap()
        XCTAssertTrue(waitUntil(timeout: 30) {
            let stored = (try? self.globalSettingsDocument(fixture.agentDirectory))?["codemode"] as? [String: Any]
            return stored?["mode"] as? String == "only"
        }, "The native Default Tools editor must persist through settings.change: \(app.debugDescription)")
        dismissTopSheet(app)
        openSettingsSection(app, "tools")
        XCTAssertEqual(codeMode.value as? String, "Codemode only", "Reopening reads the stored code-mode setting")
        keepScreenshot(app, name: "settings-surface-settings-code-mode-edit")
        dismissTopSheet(app)
        openSettingsSection(app, "setup", linkLabel: "Setup", loneRow: settingRowToken("setup.installTelemetry"))
        let globalEdit = toggleSetting(app, key: "setup.installTelemetry", confirmingReview: true)
        XCTAssertNotEqual(globalEdit.before, globalEdit.after, "the Global edit was not accepted")
        dismissTopSheet(app)
        dismissTopSheet(app)
        XCTAssertTrue(waitForNonExistence(app.navigationBars.staticTexts["Global Settings"], timeout: 15))
        openGlobalSettings()
        openSettingsSection(app, "setup", linkLabel: "Setup", loneRow: settingRowToken("setup.installTelemetry"))
        let reopenedTelemetry = topSwitchRow(app, key: "setup.installTelemetry")
        XCTAssertTrue(waitForOverride(reopenedTelemetry, timeout: 30),
                      "the reopened Settings must offer the Global reset: \(reopenedTelemetry.debugDescription)")
        XCTAssertEqual(switchValue(reopenedTelemetry), globalEdit.after, "the reopened Global value is not the accepted value")
        keepScreenshot(app, name: "settings-surface-settings-global-edit")
        dismissTopSheet(app)
        dismissTopSheet(app)
        XCTAssertTrue(waitForNonExistence(app.navigationBars.staticTexts["Global Settings"], timeout: 15))

        attachSettingsCoverage(coverage, schema: schema)
    }

    @MainActor
    func testSettingsOutsideChangesAndBuiltinExtensionPersist() throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let app = launchApp()
        defer { app.terminate() }
        open(fixture.invitationLink())
        completeFirstRunSetup(app, inWorkspace: fixture.workspace)
        XCTAssertTrue(waitForHittable(app.buttons["dashboard.menu"], timeout: 90), app.debugDescription)
        createSession(app, inWorkspace: fixture.workspace)
        let globalSettingsGear = app.navigationBars.buttons["Settings"]
        func openGlobalSettings() {
            XCTAssertTrue(globalSettingsGear.waitForExistence(timeout: 30), app.debugDescription)
            globalSettingsGear.tap()
            XCTAssertTrue(app.navigationBars.staticTexts["Global Settings"].waitForExistence(timeout: 30), app.debugDescription)
        }
        openGlobalSettings()
        openSettingsSection(app, "setup", linkLabel: "Setup", loneRow: settingRowToken("setup.installTelemetry"))
        let globalEdit = toggleSetting(app, key: "setup.installTelemetry", confirmingReview: true)
        dismissTopSheet(app)
        dismissTopSheet(app)
        XCTAssertTrue(waitForNonExistence(app.navigationBars.staticTexts["Global Settings"], timeout: 15))

        try editGlobalSettingsOutsideTron(fixture.agentDirectory) { document in
            document["enableInstallTelemetry"] = globalEdit.before == "1"
        }
        openGlobalSettings()
        openSettingsSection(app, "setup", linkLabel: "Setup", loneRow: settingRowToken("setup.installTelemetry"))
        let outsideRow = topSwitchRow(app, key: "setup.installTelemetry")
        XCTAssertEqual(switchValue(outsideRow), globalEdit.before, "the live value must follow the edited store")
        let applyAgain = hittableElement(app, identifier: settingRowToken("setup.installTelemetry") + "-applyAgain", timeout: 120)
        XCTAssertNotNil(applyAgain, "the outside change of Tron's value must offer Apply again: \(app.debugDescription)")
        keepScreenshot(app, name: "settings-surface-outside-change-apply-again")
        applyAgain?.tap()
        XCTAssertTrue(waitUntil(timeout: 60) {
            self.switchValue(outsideRow) == globalEdit.after
        }, "Apply again must restore Tron's accepted value")
        XCTAssertTrue(waitForNonExistence(app.buttons[settingRowToken("setup.installTelemetry") + "-applyAgain"], timeout: 30),
                      "Apply again must clear the canonical outside-change evidence")

        for _ in 0..<3 {
            if app.buttons["settings-done"].isHittable { break }
            dismissTopSheet(app)
        }
        XCTAssertTrue(app.buttons["settings-done"].isHittable, "Apply again must return to Settings")
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
            let entries = (try? self.globalSettingsDocument(fixture.agentDirectory))?["extensions"] as? [String] ?? []
            return entries.contains("-builtin:tool-search") == (toolSearchBefore == "1")
        }, "turning Tool search off must write -builtin:tool-search to the Global settings.json")
        keepScreenshot(app, name: "settings-surface-builtin-extension-switch")
        for _ in 0..<3 where app.navigationBars.staticTexts["Global Settings"].exists || app.switches["Tool search"].exists { dismissTopSheet(app); Thread.sleep(forTimeInterval: 1) }
        XCTAssertTrue(waitForNonExistence(app.navigationBars.staticTexts["Global Settings"], timeout: 15))

        openGlobalSettings()
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
        XCTAssertTrue(waitUntil(timeout: 15) { !outsideServer.exists && mcpLink.exists }, "dismissing MCP Servers must return to Settings")
        for _ in 0..<40 where !app.buttons["Changes"].isHittable { app.swipeDown() }
        app.buttons["Changes"].tap()
        let outsideEntry = app.staticTexts["MCP server outside-mcp"]
        XCTAssertTrue(outsideEntry.waitForExistence(timeout: 60), "Changes must list the outside MCP addition by name: \(app.debugDescription)")
        keepScreenshot(app, name: "settings-changes-outside-mcp")
        for _ in 0..<3 where app.navigationBars.staticTexts["Global Settings"].exists || outsideEntry.exists { dismissTopSheet(app); Thread.sleep(forTimeInterval: 1) }
        XCTAssertTrue(waitForNonExistence(app.navigationBars.staticTexts["Global Settings"], timeout: 15))

    }

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
        try editGlobalSettingsOutsideTron(directory) { document in
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

    private func globalSettingsDocument(_ agentDirectory: String?) throws -> [String: Any] {
        let directory = try XCTUnwrap(agentDirectory)
        let data = try Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent("settings.json"))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func editGlobalSettingsOutsideTron(_ agentDirectory: String?, _ edit: (inout [String: Any]) -> Void) throws {
        let directory = try XCTUnwrap(agentDirectory, "run through scripts/ios-gateway-e2e-test run-ui to name the fixture's agent directory")
        let store = URL(fileURLWithPath: directory).appendingPathComponent("settings.json")
        var document = (try JSONSerialization.jsonObject(with: Data(contentsOf: store)) as? [String: Any]) ?? [:]
        edit(&document)
        let staged = store.deletingLastPathComponent().appendingPathComponent("settings.json.outside-edit")
        try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted]).write(to: staged)
        _ = try FileManager.default.replaceItemAt(store, withItemAt: staged)
    }

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

    private struct SurfaceCoverage {
        var served = 0
        var rowsPresent = 0
        var optionalAbsent = 0
        var notServed = 0
        var notServedAbsent = 0
        var provenanceChecked = 0
        var valueChecked = 0
        var customOwnerChecked = 0
    }

    @MainActor
    private func assertSettingsSurface(_ app: XCUIApplication, name: String, layers: Set<String>,
                                       schema: SettingsSchemaInventory,
                                       sectionDestinations: [String: String] = [:]) -> SurfaceCoverage {
        var coverage = SurfaceCoverage()
        let isGlobalTarget = layers == ["global"]
        let surface: XCUIElement = app
        var groups: [String] = []
        for key in schema.keys where !groups.contains(key.group) { groups.append(key.group) }
        let customOwners = name == "settings" ? ["permissions.defaultProjectTrust": "Trusted Projects (#1517)",
            "sources.packages": "Extensions' Installed list (#1482)", "sources.npmCommand": "Extensions' npm command card (#1482)",
            "permissions.macTerminalServer": "this Mac's Connections page (testSettingsSourcesTextDoneAndRoutes)"] : [:]
        for group in groups {
            let rendered = schema.keys.filter { $0.group == group && !$0.layers.isDisjoint(with: layers) && customOwners[$0.id] == nil }
            let detail = openSettingsSectionIfServed(app, group, linkLabel: sectionDestinations[group],
                                                     loneRow: rendered.count == 1 ? settingRowToken(rendered[0].id) : nil)
            let snapshot: XCUIElementSnapshot
            do { snapshot = try (detail ?? surface).snapshot() }
            catch {
                XCTFail("could not read the \(name) \(group) accessibility tree: \(error)")
                return coverage
            }
            let elements = [snapshot] + descendants(of: snapshot)
            for key in schema.keys where key.group == group {
                var keyElements = elements
                var instances: XCUIElement?
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
                let rows = keyElements.filter {
                    $0.elementType == .other && ($0.identifier == token || $0.identifier.hasPrefix(token + "_"))
                        && !$0.identifier.hasSuffix("-project") && !$0.identifier.hasSuffix("-reset")
                        && !$0.identifier.hasSuffix("-applyAgain") && !$0.identifier.hasSuffix("-error")
                }
                let globalInstancesOnly = key.qualifier == "key" || key.qualifier == "device"
                let served = !key.layers.isDisjoint(with: layers) && (!globalInstancesOnly || isGlobalTarget)
                guard served else {
                    coverage.notServed += 1
                    XCTAssertEqual(rows.count, 0, "\(name) must not show \(key.id): it is not served on this surface")
                    if rows.count == 0 { coverage.notServedAbsent += 1 }
                    continue
                }
                coverage.served += 1
                if key.id == "tools.codemode.mode" && (name == "settings" || name == "project") {
                    XCTAssertEqual(rows.count, 0, "There must not be a duplicate Code mode editor")
                    let controls = elements.filter { $0.elementType == .button && $0.label == "Other tools with codemode" }
                    XCTAssertEqual(controls.count, 1, "\(name) must expose its owning Default Tools control")
                    XCTAssertEqual(controls.first?.value as? String, "Both", "Read the fresh fixture's default")
                    coverage.customOwnerChecked += 1
                    coverage.valueChecked += 1
                    continue
                }
                if let owner = customOwners[key.id] {
                    XCTAssertEqual(rows.count, 0, "\(name) must not repeat \(key.id) beside \(owner)")
                    coverage.customOwnerChecked += 1
                    continue
                }
                guard rows.count > 0 else {
                    XCTAssertTrue((key.qualifier == "project" || key.qualifier == "device") && isGlobalTarget,
                                  "\(name) serves \(key.id) but shows no row")
                    coverage.optionalAbsent += 1
                    continue
                }
                coverage.rowsPresent += 1
                let row = rows[0]
                let children = descendants(of: row)
                let rowElement = instances == nil && detail?.identifier == row.identifier ? detail!
                    : (instances ?? detail ?? surface).descendants(matching: .any).matching(identifier: row.identifier).firstMatch
                let provenance = rowProvenance(rowElement)
                let reverts = provenance.contains("Revert") || provenance.contains("Reset")
                XCTAssertEqual(provenance.contains("Overridden"), reverts && !isGlobalTarget,
                               "\(name) row \(key.id) marks an override exactly beside its revert: \(provenance)")
                XCTAssertFalse(reverts && provenance.contains("Set by Project settings"),
                               "\(name) row \(key.id) cannot revert a repository value: \(provenance)")
                coverage.provenanceChecked += 1
                let described = children.map(\.label)
                    + children.filter { $0.elementType == .switch }.compactMap { $0.value as? String }
                XCTAssertTrue(described.contains { !$0.isEmpty && $0 != key.label && !provenanceWords.contains($0) },
                              "\(name) row \(key.id) shows no value: \(described)")
                coverage.valueChecked += 1
            }
            if let detail {
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

    @MainActor
    func openSettingsSection(_ app: XCUIApplication, _ group: String, linkLabel: String? = nil, loneRow: String? = nil) {
        XCTAssertNotNil(openSettingsSectionIfServed(app, group, linkLabel: linkLabel, loneRow: loneRow),
                        "the \(group) section has no settings link: \(app.debugDescription)")
    }

    @MainActor
    func openSettingsSectionIfServed(_ app: XCUIApplication, _ group: String,
                                           linkLabel: String? = nil, loneRow: String? = nil) -> XCUIElement? {
        let links = linkLabel.map { app.buttons.matching(NSPredicate(format: "label == %@", $0)) }
            ?? app.buttons.matching(identifier: "settings-section-\(group)-open")
        guard links.firstMatch.waitForExistence(timeout: 5) else { return nil }
        let link = links.allElementsBoundByIndex.last!
        func barBottom() -> CGFloat { app.navigationBars.allElementsBoundByIndex.last?.frame.maxY ?? 0 }
        for _ in 0..<24 where !(link.isHittable && link.frame.minY >= barBottom()) {
            if link.frame.minY < barBottom() + 40 { app.swipeDown() } else { app.swipeUp() }
        }
        guard link.isHittable, link.frame.minY >= barBottom() else { return nil }
        link.tap()
        let details = app.descendants(matching: .any).matching(identifier: "settings-section-\(group)-detail")
        let lone = loneRow.map { app.descendants(matching: .any).matching(identifier: $0) }
        if let linkLabel {
            XCTAssertTrue(app.navigationBars.staticTexts[linkLabel].waitForExistence(timeout: 30),
                          "the \(linkLabel) destination did not open: \(app.debugDescription)")
            for _ in 0..<24 where !details.firstMatch.exists && lone?.firstMatch.exists != true { app.swipeUp() }
        }
        if let lone, !details.firstMatch.exists, lone.firstMatch.waitForExistence(timeout: 30) {
            return lone.element(boundBy: max(lone.count - 1, 0))
        }
        XCTAssertTrue(details.firstMatch.waitForExistence(timeout: 30),
                      "the \(group) sub-sheet did not open: \(app.debugDescription)")
        let detail = details.element(boundBy: max(details.count - 1, 0))
        return detail
    }

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

    @MainActor
    func revealBelowNavigationBar(_ app: XCUIApplication, _ element: XCUIElement) {
        for _ in 0..<40 {
            let bar = app.navigationBars.allElementsBoundByIndex.last
            if element.isHittable, element.frame.minY >= (bar?.frame.maxY ?? 0) { return }
            if element.exists && element.frame.minY < (bar?.frame.maxY ?? 0) {
                app.swipeDown()
            } else {
                app.swipeUp()
            }
        }
    }

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

    @MainActor
    func revealedElement(_ app: XCUIApplication, where predicate: NSPredicate, timeout: TimeInterval = 20) -> XCUIElement? {
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
    func dismissTopSheet(_ app: XCUIApplication) {
        guard let done = revealedElement(app, where: NSPredicate(format: "label == %@", "Done"), timeout: 10) else {
            XCTFail("no hittable Done control to dismiss the presented sheet: \(app.debugDescription)")
            return
        }
        done.tap()
    }

    @MainActor
    private func openProjectCard(_ app: XCUIApplication) {
        let link = app.buttons["chat-settings-link"]
        XCTAssertTrue(link.waitForExistence(timeout: 30), "Manage Session has no Session Settings link: \(app.debugDescription)")
        for _ in 0..<12 where !link.isHittable { app.swipeUp() }
        link.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Session Settings"].waitForExistence(timeout: 15), app.debugDescription)
        let section = app.descendants(matching: .any)["session-project-settings"]
        XCTAssertTrue(section.waitForExistence(timeout: 30), "Session Settings has no Project section: \(app.debugDescription)")
        for _ in 0..<12 where !app.buttons["project-settings-trust"].isHittable { app.swipeUp() }
    }

    private func switchValue(_ row: XCUIElement) -> String? {
        row.switches.firstMatch.value.map { String(describing: $0) }
    }

    @MainActor
    private func toggleSetting(_ app: XCUIApplication, key: String, confirmingReview: Bool = false) -> (before: String?, after: String?) {
        XCTAssertTrue(settingRow(app, key: key).waitForExistence(timeout: 15), "\(key) has no row: \(app.debugDescription)")
        let row = topSwitchRow(app, key: key)
        let toggle = row.switches.firstMatch
        let before = switchValue(row)
        toggle.tap()
        if confirmingReview {
            let approve = app.buttons["change-review-approve"]
            XCTAssertTrue(approve.waitForExistence(timeout: 30), "\(key) must ask for its exact review: \(app.debugDescription)")
            approve.tap()
        }
        XCTAssertTrue(waitUntil(timeout: 60) { self.switchValue(row) != before },
                      "The Gateway did not accept the \(key) value")
        let after = switchValue(row)
        XCTAssertTrue(waitForOverride(row, timeout: 30), "The accepted value must be this scope's override: \(rowProvenance(row))")
        XCTAssertEqual(switchValue(row), after, "Reading provenance must not mutate the accepted value")
        return (before, after)
    }

    @MainActor
    private func waitForOverride(_ row: XCUIElement, timeout: TimeInterval) -> Bool {
        row.waitForExistence(timeout: timeout)
            && row.buttons.matching(identifier: row.identifier + "-reset").firstMatch.waitForExistence(timeout: timeout)
    }

    @MainActor
    private func rowProvenance(_ row: XCUIElement) -> [String] {
        guard row.exists, let snapshot = try? row.snapshot() else { return [] }
        return ([snapshot] + descendants(of: snapshot)).map(\.label).filter(provenanceWords.contains)
    }

    @MainActor
    private func waitForNonExistence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) { !element.exists }
    }

    @MainActor
    func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
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
             "provenanceChecked": surface.provenanceChecked, "valueChecked": surface.valueChecked,
             "customOwnerChecked": surface.customOwnerChecked]
        }
        let report: [String: Any] = ["schema": "tron.ios-settings-surface-coverage.v1", "schemaKeys": schema.keys.count,
                                     "surfaces": surfaces]
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    @MainActor
    func launchApp(resettingState: Bool = true, additionalArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = (resettingState ? ["--tron-reset-ui-test-state"] : []) + [
            "-ApplePersistenceIgnoreState",
            "YES",
        ] + additionalArguments
        app.launch()
        return app
    }

    @MainActor
    func completeFirstRunSetup(_ app: XCUIApplication, inWorkspace workspace: String) {
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
        if app.buttons["Open Without Resources"].waitForExistence(timeout: 10) {
            app.buttons["Open Without Resources"].tap()
        }
        advanceSetup(app)
        let finish = app.buttons["Finish setup"]
        XCTAssertTrue(finish.waitForExistence(timeout: 60), "setup never reached its model step: \(app.debugDescription)")
        XCTAssertTrue(waitForEnabled(finish, timeout: 90), "the model step never selected a model: \(app.debugDescription)")
        finish.tap()
    }

    @MainActor
    func advanceSetup(_ app: XCUIApplication) {
        for step in 0..<4 {
            let next = app.buttons["Next"]
            XCTAssertTrue(
                waitForEnabled(next, timeout: 60),
                "setup page \(step + 1) after the workspace never became complete: \(app.debugDescription)"
            )
            next.tap()
        }
    }

    @MainActor
    func open(_ link: String) {
        XCUIDevice.shared.system.open(URL(string: link)!)
    }

    @MainActor
    func createSession(_ app: XCUIApplication, inWorkspace workspace: String,
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

    func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)
        return XCTWaiter().wait(for: [enabled], timeout: timeout) == .completed
    }

    @MainActor
    func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: element)
        return XCTWaiter().wait(for: [hittable], timeout: timeout) == .completed
    }

    @MainActor
    func setProxyMode(_ fixture: RealGatewayUIFixture, mode: String, code: Int? = nil, timeout: TimeInterval = 15) throws {
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
        wait(for: [completed], timeout: timeout)
    }

    @MainActor
    private func recoveryStatus(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

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

    @MainActor
    private func transcriptRows(_ app: XCUIApplication) -> CGImage? {
        let screenshot = app.screenshot().image
        let scale = screenshot.scale
        return screenshot.cgImage?.cropping(to: CGRect(x: 30 * scale, y: 150 * scale,
                                                       width: 330 * scale, height: 260 * scale))
    }

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
    func keepScreenshot(_ app: XCUIApplication, name: String) {
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = name
        capture.lifetime = .keepAlways
        add(capture)
    }
}

@MainActor
private enum RealGatewayUIHost {
    static func resetHostedAppState() {
        let app = XCUIApplication()
        app.launchArguments = ["--tron-reset-ui-test-state", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        app.terminate()
    }
}

struct RealGatewayUIFixture {
    let host = "127.0.0.1"
    let port: Int
    let code: String
    let workspace: String
    let tronHome: URL
    var agentDirectory: String? = nil

    static func fromEnvironment() throws -> RealGatewayUIFixture {
        let environment = ProcessInfo.processInfo.environment
        guard let tronHome = environment["TRON_E2E_TRON_HOME"], !tronHome.isEmpty else {
            throw NSError(domain: "RealGatewayUIFixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "TRON_E2E_TRON_HOME is required from the canonical Gateway fixture."])
        }
        guard let portText = environment["TRON_E2E_PORT"], let port = Int(portText),
              let code = environment["TRON_E2E_CODE"],
              let workspace = environment["TRON_E2E_WORKSPACE"] else {
            throw XCTSkip("Run through scripts/ios-gateway-e2e-test run-ui to provide the real Gateway fixture.")
        }
        return RealGatewayUIFixture(port: port, code: code, workspace: workspace,
                                    tronHome: URL(fileURLWithPath: tronHome), agentDirectory: environment["TRON_E2E_AGENT_DIR"])
    }

    func invitationLink(code: String? = nil) -> String {
        "tron://pair?host=\(host)&port=\(port)&code=\(code ?? self.code)"
    }
}

private let provenanceWords: Set<String> = ["Overridden", "Revert", "Reset", "Set by Project settings", "Apply again"]

private struct SettingsSchemaInventory {
    struct Key {
        let id: String
        let label: String
        let group: String
        let layers: Set<String>
        let qualifier: String?
    }

    let keys: [Key]

    static func fromEnvironment() throws -> SettingsSchemaInventory {
        guard let text = ProcessInfo.processInfo.environment["TRON_E2E_SETTINGS_INVENTORY"] else {
            throw XCTSkip("Run through scripts/ios-gateway-e2e-test run-ui to provide the fixture's settings schema inventory.")
        }
        guard let document = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let rows = document["keys"] as? [[String: Any]], !rows.isEmpty else {
            throw SettingsInventoryError.malformed
        }
        let keys = try rows.map { row -> Key in
            guard let id = row["id"] as? String, let label = row["label"] as? String, let group = row["group"] as? String,
                  let layers = row["layers"] as? [String] else { throw SettingsInventoryError.malformed }
            return Key(id: id, label: label, group: group, layers: Set(layers), qualifier: row["qualifier"] as? String)
        }
        return SettingsSchemaInventory(keys: keys)
    }
}

private enum SettingsInventoryError: Error { case malformed }

private func settingRowToken(_ key: String) -> String {
    "settings-row-" + String(key.unicodeScalars.map { scalar in
        CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" ? Character(scalar) : "_"
    })
}
