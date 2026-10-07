import CoreML
import UIKit
import Vision
import XCTest

final class TronSmokeUITests: XCTestCase {
    @MainActor
    func testHomePinnedRowCapabilityDesignationAndExactProfileRoute() {
        continueAfterFailure = false
        let unsupported = XCUIApplication()
        unsupported.launchArguments = ["-tron-home-dashboard-fixture", "-home-capability-absent"]
        unsupported.launch()
        XCTAssertFalse(unsupported.buttons["home-pinned-row"].exists)
        let ordinary = unsupported.buttons["session-row-home-shell-fixture:ordinary-session"]
        XCTAssertTrue(ordinary.waitForExistence(timeout: 10), unsupported.debugDescription)
        ordinary.tap()
        XCTAssertTrue(unsupported.staticTexts["Ordinary session chat"].waitForExistence(timeout: 10))
        unsupported.terminate()

        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture"]
        app.launch()
        let home = app.buttons["home-pinned-row"]
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        home.tap()
        XCTAssertTrue(app.staticTexts["Home fixture chat"].waitForExistence(timeout: 10))
        app.terminate()

        let setup = XCUIApplication()
        setup.launchArguments = ["-tron-home-dashboard-fixture"]
        setup.launch()
        let designate = setup.buttons["home-pinned-row"]
        XCTAssertTrue(designate.waitForExistence(timeout: 10))
        designate.tap()
        XCTAssertTrue(setup.staticTexts["Home fixture chat"].waitForExistence(timeout: 10))
        XCTAssertTrue(setup.staticTexts["fixture.home-diagnostics"].label.contains("home-shell-fixture"))
        setup.terminate()
    }

    @MainActor
    func testHomeChatStatusPollingResumesAfterCoveredSettingsSheet() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture"]
        app.launch()
        let home = app.buttons["home-pinned-row"]
        XCTAssertTrue(home.waitForExistence(timeout: 10), app.debugDescription)
        home.tap()
        XCTAssertTrue(app.staticTexts["Home fixture chat"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["fixture.home-diagnostics"].label.contains("home-shell-fixture"))
        let count = app.staticTexts["fixture.home-status-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        let initialCount = Int(count.label.split(separator: ":").last ?? "0") ?? 0
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 5.5)
        app.buttons["Done"].tap()
        let increased = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            Int(count.label.split(separator: ":").last ?? "0").map { $0 > initialCount } ?? false
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [increased], timeout: 7), .completed)
        app.terminate()
    }

    @MainActor
    func testBlockedHomeRowDoesNotClaimReadiness() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-row-appearance-fixture", "-home-blocked"]
        app.launch()
        let row = app.buttons["home-pinned-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("Blocked"), row.label)
        XCTAssertFalse(row.label.contains("Ready"), row.label)
        app.terminate()
    }

    @MainActor
    func testHomePinnedRowLightDarkAndAccessibilityCaptures() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            for type in ["normal", "accessibility"] {
                let app = XCUIApplication()
                app.launchArguments = ["-tron-home-row-appearance-fixture"]
                if appearance == "dark" { app.launchArguments.append("-home-dark") }
                if type == "accessibility" { app.launchArguments.append("-home-accessibility-type") }
                app.launch()
                XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.staticTexts["ordinary-session-row"].exists)
                keepScreenshot(named: "home-pinned-\(appearance)-\(type)")
                app.terminate()
            }
        }
    }

    // Failure modes: an unexplained disabled control; pending work mistaken for
    // a lock; browsing/dismissal blocked; receipt settlement leaving controls stuck.
    @MainActor
    func testConfigurationFeedbackExplainsLockAndPendingWithoutBlockingBrowsing() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-session-configuration-fixture", "-fixture-appearance", appearance]
            app.launch()
            defer { app.terminate() }
            XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 5))
            app.buttons["Stop session"].tap()
            let thinking = app.buttons["thinking-level-control"]
            XCTAssertTrue(thinking.waitForExistence(timeout: 5))
            XCTAssertFalse(thinking.isEnabled)
            keepScreenshot(named: "configuration-lock-\(appearance)")
            let explanation = app.buttons["Why configuration is unavailable"]
            XCTAssertTrue(explanation.waitForExistence(timeout: 3), "A disabled control needs a touch-accessible explanation")
            explanation.tap()
            XCTAssertTrue(app.staticTexts["Finishing the session. Configuration will be available shortly."].waitForExistence(timeout: 3))
            keepScreenshot(named: "configuration-lock-explanation-\(appearance)")
            app.buttons["Done"].tap()
            app.buttons["Release terminal settlement"].tap()
            wait(for: [expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: thinking)], timeout: 5)
            thinking.tap()
            let slider = app.descendants(matching: .any)["thinking-level-slider"]
            XCTAssertTrue(slider.waitForExistence(timeout: 3))
            slider.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            app.buttons["Done"].tap()
            wait(for: [expectation(for: NSPredicate(format: "enabled == false"), evaluatedWith: thinking)], timeout: 5)
            let switchModel = app.buttons["Switch Model"]
            XCTAssertTrue(switchModel.isEnabled, "Pending configuration must not block model browsing")
            XCTAssertEqual(switchModel.value as? String, "Applying configuration")
            keepScreenshot(named: "configuration-applying-\(appearance)")
            switchModel.tap()
            let selected = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Fixture Model")).firstMatch
            XCTAssertTrue(selected.waitForExistence(timeout: 3))
            XCTAssertFalse(selected.isEnabled)
            XCTAssertEqual(selected.value as? String, "Applying configuration")
            keepScreenshot(named: "models-applying-\(appearance)")
            app.buttons["Search models"].tap()
            let search = app.textFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 3))
            if app.buttons["Continue"].exists { app.buttons["Continue"].tap() }
            search.typeText("Alternative")
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Alternative Model")).firstMatch.waitForExistence(timeout: 3))
            app.buttons["Close search"].tap()
            app.buttons["Done"].tap()
            app.buttons["Complete superseded thinking"].tap()
            XCTAssertTrue(app.staticTexts["Superseded receipt delivered"].waitForExistence(timeout: 5))
            wait(for: [expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: thinking)], timeout: 5)
            XCTAssertEqual(thinking.value as? String, "Off")
            XCTAssertFalse(app.buttons["Why configuration is unavailable"].exists)
            app.terminate()
        }
    }

    @MainActor
    func testSupersededThinkingReceiptReleasesMountedConfiguration() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-configuration-fixture"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 5))
        app.buttons["Stop session"].tap()
        app.buttons["Release terminal settlement"].tap()
        let thinking = app.buttons["thinking-level-control"]
        wait(for: [expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: thinking)], timeout: 5)
        thinking.tap()
        let slider = app.descendants(matching: .any)["thinking-level-slider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 3))
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.buttons["Done"].tap()
        wait(for: [expectation(for: NSPredicate(format: "enabled == false"), evaluatedWith: thinking)], timeout: 5)
        app.buttons["Complete superseded thinking"].tap()
        XCTAssertTrue(app.staticTexts["Superseded receipt delivered"].waitForExistence(timeout: 5))
        wait(for: [expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: thinking)], timeout: 5)
        XCTAssertTrue(thinking.value as? String == "Off")
        thinking.tap()
        XCTAssertTrue(slider.waitForExistence(timeout: 3), "Another edit must work without reopening Manage Session")
        keepScreenshot(named: "superseded-thinking-receipt-ready")
    }

    @MainActor
    func testPostStopConfigurationWaitsForSettlementThenEnablesWithoutReopening() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-configuration-fixture"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 5))
        app.buttons["Stop session"].tap()
        let thinking = app.buttons["thinking-level-control"]
        XCTAssertTrue(thinking.waitForExistence(timeout: 5))
        XCTAssertFalse(thinking.isEnabled, "Foreground Stop alone must not make settling configuration editable")
        let explanation = app.buttons["Why configuration is unavailable"]
        XCTAssertTrue(explanation.exists)
        explanation.tap()
        XCTAssertTrue(app.staticTexts["Finishing the session. Configuration will be available shortly."].waitForExistence(timeout: 3))
        keepScreenshot(named: "post-stop-configuration-settling")
        app.buttons["Done"].tap()
        app.buttons["Release terminal settlement"].tap()
        let enabled = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: thinking)
        wait(for: [enabled], timeout: 5)
        thinking.tap()
        XCTAssertTrue(app.descendants(matching: .any)["thinking-level-slider"].waitForExistence(timeout: 3))
        keepScreenshot(named: "post-stop-configuration-ready")
    }

    @MainActor
    func testIntegrationDestinationsHaveOneDoneButtonThroughSettings() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-navigation-fixture"]
        for title in ["Connected Services", "MCP Servers"] {
            app.launch()
            let destination = app.buttons[title]
            XCTAssertTrue(destination.waitForExistence(timeout: 5))
            for _ in 0..<3 where !destination.isHittable { app.swipeUp() }
            XCTAssertTrue(destination.isHittable)
            destination.tap()
            let done = app.buttons.matching(NSPredicate(format: "label == %@", "Done"))
            XCTAssertTrue(done.firstMatch.waitForExistence(timeout: 3))
            XCTAssertEqual(done.allElementsBoundByIndex.filter(\.isHittable).count, 1,
                           "Only the progressive settings shell owns dismissal")
            keepScreenshot(named: "settings-\(title)-single-done-light")
            done.allElementsBoundByIndex.first(where: \.isHittable)?.tap()
            XCTAssertTrue(app.buttons["Agent Defaults"].waitForExistence(timeout: 3))
            app.terminate()
        }
    }

    @MainActor
    func testAgentDefaultsThinkingSliderOpensAfterDefaultsConsolidation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-agent-defaults-fixture"]
        app.launch()
        defer { app.terminate() }
        let control = app.buttons.matching(identifier: "thinking-level-control")
            .matching(NSPredicate(format: "label == %@", "Thinking")).firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        XCTAssertTrue(control.isEnabled)
        control.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "thinking-level-slider").firstMatch.waitForExistence(timeout: 3))
        keepScreenshot(named: "agent-defaults-thinking-editor-fixture")
    }

    @MainActor
    func testKnowledgeSettingsSubmenuStaysOpenDuringParentUpdates() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-dashboard-menu-fixture"]
        app.launch()
        defer { app.terminate() }
        app.buttons["Begin updates"].tap()
        app.buttons["dashboard.menu"].tap()
        app.buttons["Knowledge settings"].tap()
        let configuration = app.buttons["Observation configuration"]
        XCTAssertTrue(configuration.waitForExistence(timeout: 3))
        // The fixture performs thirty controlled parent updates. Wait for its
        // completion while the actual tapped submenu remains presented.
        let finished = NSPredicate(format: "label == %@", "Revision 30")
        let updates = expectation(for: finished, evaluatedWith: app.staticTexts["menu-fixture-revision"])
        wait(for: [updates], timeout: 10)
        XCTAssertTrue(configuration.isHittable, "Parent updates must not dismiss the native submenu")
        XCTAssertTrue(app.buttons["Connectors"].exists)
        XCTAssertTrue(app.buttons["Import legacy records"].exists)
        keepScreenshot(named: "knowledge-settings-submenu-after-updates")
        configuration.tap()
        XCTAssertTrue(app.staticTexts["menu-fixture-selection"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testOnboardingPreservesPagedSheetAndPairingJourney() {
        let app = launchResetApp()
        let title = app.staticTexts["Welcome to Tron"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Sheet Grabber"].exists)
        XCTAssertTrue(app.staticTexts["Pair this iPhone with the Mac running Tron."].exists)
        XCTAssertTrue(app.buttons["Open Tron navigation"].exists)
        XCTAssertTrue(app.buttons["Settings"].exists)
        let pageIndicator = app.descendants(matching: .any)["Onboarding step 1 of 9"]
        XCTAssertTrue(pageIndicator.exists)
        let next = app.buttons["Next"]
        XCTAssertLessThan(abs(next.frame.width - next.frame.height), 2, "The native sheet navigation control must be circular")
        XCTAssertGreaterThanOrEqual(next.frame.width, 34)
        XCTAssertLessThan(abs(title.frame.midX - app.frame.midX), 18)
        XCTAssertLessThan(abs(title.frame.midY - next.frame.midY), 20)
        XCTAssertGreaterThan(title.frame.minY, app.frame.height * 0.45)
        assertWelcomeVisualParity()
        keepScreenshot(named: "onboarding-welcome-medium-current")

        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["Install Tailscale"].waitForExistence(timeout: 2))
        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["Install Tron on Mac"].waitForExistence(timeout: 2))
        app.buttons["Next"].tap()

        XCTAssertTrue(app.staticTexts["Connect a Mac"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Scan QR code"].exists)
        XCTAssertTrue(app.buttons["Enter Manually"].exists)
        app.buttons["Enter Manually"].tap()
        XCTAssertTrue(app.textFields["Tailscale host"].exists)
        XCTAssertTrue(app.textFields["Port"].exists)
        XCTAssertTrue(app.secureTextFields["One-time code"].exists)
        let connect = app.buttons["Connect to Mac"]
        XCTAssertFalse(connect.isEnabled)
        XCTAssertGreaterThanOrEqual(connect.frame.width, 72, "Connect must retain default iOS toolbar horizontal insets")
        XCTAssertGreaterThanOrEqual(connect.frame.height, 35, "Connect must retain default iOS toolbar control height")
        keepScreenshot(named: "onboarding-pairing-large-current")
        assertAccessibilityAuditPasses(app)
    }

    @MainActor
    func testOnboardingPairingPassesAccessibilityAuditInLightMode() {
        let app = launchResetApp(extraArguments: ["-appearanceMode", "light"])
        for _ in 0..<3 { app.buttons["Next"].tap() }
        app.buttons["Enter Manually"].tap()
        XCTAssertTrue(app.secureTextFields["One-time code"].waitForExistence(timeout: 3))
        assertAccessibilityAuditPasses(app)
    }

    @MainActor
    func testPairingValidationIsAccessibleAndDoesNotLeaveOnboarding() {
        let app = launchResetApp()
        for _ in 0..<3 { app.buttons["Next"].tap() }
        app.buttons["Enter Manually"].tap()

        let host = app.textFields["Tailscale host"]
        let code = app.secureTextFields["One-time code"]
        host.tap(); host.typeText("not a host/path")
        code.tap(); code.typeText("NOTREAL1")
        if app.keyboards.buttons["return"].exists { app.keyboards.buttons["return"].tap() }
        else { app.tap() }
        app.buttons["Connect to Mac"].tap()

        XCTAssertTrue(app.alerts["Tron"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Enter a valid host, port, and one-time code."].exists)
        app.alerts["Tron"].buttons["OK"].tap()
        XCTAssertTrue(app.secureTextFields["One-time code"].waitForExistence(timeout: 2), app.debugDescription)
    }

    @MainActor
    func testPairingFieldsScaleAtAccessibilityXXXL() {
        let app = launchResetApp(extraArguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ])
        for _ in 0..<3 { app.buttons["Next"].tap() }
        app.buttons["Manual Entry"].tap()

        let host = app.textFields["Tailscale host"]
        XCTAssertTrue(host.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(host.frame.height, 52, "The custom host field must grow at accessibility XXXL")
        XCTAssertTrue(app.textFields["Port"].exists)
        let code = app.secureTextFields["One-time code"]
        if !code.exists { app.swipeUp() }
        XCTAssertTrue(code.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(code.frame.height, 40, "The inner UIKit secure field must scale at accessibility XXXL")
    }

    @MainActor
    func testOnboardingSheetSupportsNativeExpansionGesture() {
        let app = launchResetApp()
        let title = app.staticTexts["Welcome to Tron"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let initialY = title.frame.minY
        app.swipeUp()
        let expanded = NSPredicate { element, _ in
            guard let element = element as? XCUIElement else { return false }
            return element.frame.minY < initialY - 80
        }
        expectation(for: expanded, evaluatedWith: title)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    func testAskUserAllowCancelCancelSendsExactlyOneScopedCancellation() {
        let app = launchAskUser(multiple: true)
        waitForAskUserForm(in: app)
        let cancel = app.buttons["Cancel form"]
        let close = app.buttons["Close form and keep answers"]
        let send = app.buttons["Submit all answers"]
        XCTAssertTrue(cancel.exists && close.exists && send.exists)
        XCTAssertLessThan(cancel.frame.maxX, app.frame.midX)
        XCTAssertGreaterThan(close.frame.minX, app.frame.midX)
        XCTAssertLessThanOrEqual(close.frame.maxX, send.frame.minX)
        keepScreenshot(named: "ask-user-cancel-left-close-send-right")
        cancel.tap()
        XCTAssertTrue(app.staticTexts["Mutation count: 1"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["extension.respond cancelled=true scope=ask-user-interaction/hosted-ask-user-epoch/1"].exists)
        XCTAssertFalse(app.staticTexts["Mutation count: 2"].exists)
        let cancelled = app.staticTexts["Cancelled — no answers submitted"].firstMatch
        XCTAssertTrue(cancelled.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["This question was cancelled."].exists)
        XCTAssertFalse(app.staticTexts["No answers submitted"].exists)
        let progress = app.staticTexts["1/2"]
        XCTAssertTrue(progress.exists)
        XCTAssertLessThan(abs(cancelled.frame.midY - progress.frame.midY), 8)
        keepScreenshot(named: "ask-user-cancelled-single-status-row")
    }

    @MainActor
    func testExtensionWidgetsSheetRendersRetainedContent() {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-extension-widgets-fixture"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Extension widgets fixture"].waitForExistence(timeout: 10), app.debugDescription)
        let sheet = app.otherElements["session-activity-sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), app.debugDescription)
        // Producer attribution for both retained kinds.
        XCTAssertTrue(app.staticTexts["Goal"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.staticTexts["npm:fixture-extension"].exists)
        // String widget lines render as native text.
        XCTAssertTrue(app.staticTexts["Goal active"].exists)
        XCTAssertTrue(app.staticTexts["Used 12k tokens"].exists)
        // A retained status is presentable on its own, which is the only content a
        // paused goal leaves behind after it clears its widget.
        XCTAssertTrue(app.staticTexts["Goal paused (/goal resume)"].exists)
        // An ownerless status is grouped, never dropped.
        XCTAssertTrue(app.staticTexts["Unknown extension"].exists)
        // A retained read-only component frame renders its sanitized content.
        let frameText = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Frame progress 3 of 5")
        ).firstMatch
        XCTAssertTrue(frameText.waitForExistence(timeout: 3), app.debugDescription)
        // Admitted-but-unpresentable content is disclosed, not silently dropped.
        XCTAssertTrue(app.staticTexts["Some extension content is not shown on this device yet."].exists)
        keepScreenshot(named: "extension-widgets-sheet-content")
        app.buttons["Done"].tap()
        XCTAssertFalse(sheet.waitForExistence(timeout: 2))
    }

    /// Failure modes: attributed sections are dropped or reordered, the overview
    /// leaks section entries, the overview or a section sheet opens beyond its
    /// medium detent, a section sheet omits its purpose or attributed sources,
    /// or an instruction file cannot be read in full.
    @MainActor
    func testAgentInstructionsSectionsOpenSheetsWithTheirSources() {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-agent-instructions-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let order = ["preamble", "tools", "rules", "docs", "project_context", "skills", "cwd", "tron"]
        let headers = order.map { app.buttons["agent-instructions-section-\($0)"] }
        XCTAssertTrue(headers[0].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(headers.allSatisfy(\.exists), app.debugDescription)
        XCTAssertEqual(headers.map(\.frame.minY), headers.map(\.frame.minY).sorted(), "Sections must keep the model's reading order")
        XCTAssertTrue(headers[7].label.contains("Each turn"), "The per-turn Tron context must be marked: \(headers[7].label)")
        XCTAssertFalse(entry(app, "tools.1").exists, "The overview must not show section entries")
        let screenHeight = app.windows.firstMatch.frame.height
        XCTAssertGreaterThan(headers[0].frame.minY, screenHeight * 0.35, "The overview must open at its medium detent")
        keepScreenshot(named: "agent-instructions-overview")

        headers[1].tap()
        let subagent = entry(app, "tools.1")
        XCTAssertTrue(subagent.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(subagent.label.contains("subagent") && subagent.label.contains("Package"), subagent.label)
        XCTAssertTrue(entry(app, "tools.2").label.contains("Tron"))
        let purpose = app.descendants(matching: .any)["agent-instructions-purpose"]
        XCTAssertGreaterThan(purpose.frame.minY, screenHeight * 0.35, "A section sheet must open at its medium detent")
        keepScreenshot(named: "agent-instructions-tools-sheet")
        dismissTopSheet(app, revealing: headers[2])

        headers[2].tap()
        XCTAssertTrue(entry(app, "rules.1").waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(entry(app, "rules.1").label.contains("from subagent"), entry(app, "rules.1").label)
        dismissTopSheet(app, revealing: headers[7])

        headers[7].tap()
        let tronPurpose = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Added by Tron at the start of every turn")).firstMatch
        XCTAssertTrue(tronPurpose.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(labelled(app, "Tron module tron-core").exists, app.debugDescription)
        XCTAssertTrue(labelled(app, "Added each turn").exists, app.debugDescription)
        keepScreenshot(named: "agent-instructions-tron-sheet")
        dismissTopSheet(app, revealing: headers[4])

        headers[4].tap()
        let agents = app.buttons["agent-instructions-entry-project_context.0"]
        XCTAssertTrue(agents.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(agents.label.contains("~/Workspace/project/AGENTS.md"), agents.label)
        agents.tap()
        let fileBody = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", "Code, tests, and docs ship together.", "Code, tests, and docs ship together."
        )).firstMatch
        XCTAssertTrue(fileBody.waitForExistence(timeout: 5), app.debugDescription)
        keepScreenshot(named: "agent-instructions-file-reader")
    }

    private func entry(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)["agent-instructions-entry-\(id)"]
    }

    private func labelled(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Done on the frontmost sheet; the covered overview's Done stays in the tree.
    private func dismissTopSheet(_ app: XCUIApplication, revealing element: XCUIElement) {
        let done = app.buttons.matching(NSPredicate(format: "label == %@", "Done"))
        done.element(boundBy: done.count - 1).tap()
        let closed = expectation(for: NSPredicate(format: "exists == false"),
                                 evaluatedWith: app.descendants(matching: .any)["agent-instructions-purpose"])
        wait(for: [closed], timeout: 3)
        XCTAssertTrue(element.exists, app.debugDescription)
    }

    @MainActor
    func testExtensionWidgetsSheetKeepsContentReachableAtAccessibilityXXXL() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-tron-extension-widgets-fixture",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        let sheet = app.otherElements["session-activity-sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), app.debugDescription)
        // Every retained entry must still be reachable and read at the largest
        // accessibility size; the sheet scrolls instead of truncating content.
        for label in ["Goal", "Goal active", "Used 12k tokens", "Goal paused (/goal resume)"] {
            let text = app.staticTexts[label]
            if !text.exists { app.swipeUp() }
            XCTAssertTrue(text.waitForExistence(timeout: 3), app.debugDescription)
        }
        let frameText = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Frame progress 3 of 5")
        ).firstMatch
        if !frameText.exists { app.swipeUp() }
        XCTAssertTrue(frameText.waitForExistence(timeout: 3), app.debugDescription)
        keepScreenshot(named: "extension-widgets-sheet-accessibility-xxxl")
    }

    @MainActor
    func testSessionPaginationKeepsShowLessBesideShowMoreAndClearOfLogo() {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-pagination-fixture"]
        app.launch()
        let more = app.buttons["Show more sessions in Example workspace"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), app.debugDescription)
        more.tap()
        let less = app.buttons["Show less sessions in Example workspace"]
        for _ in 0..<8 where !less.isHittable { app.swipeUp() }
        XCTAssertTrue(more.isHittable)
        XCTAssertTrue(less.isHittable)
        XCTAssertEqual(less.frame.minX - more.frame.maxX, 24, accuracy: 2)
        XCTAssertEqual(less.frame.minY, more.frame.minY, accuracy: 2)
        let logo = app.buttons["dashboard.menu"]
        XCTAssertFalse(less.frame.intersects(logo.frame))
        keepScreenshot(named: "session-pagination-grouped-at-scroll-end")
        more.tap()
        for _ in 0..<8 where !less.isHittable { app.swipeUp() }
        XCTAssertTrue(less.isHittable)
        XCTAssertFalse(more.exists)
        XCTAssertLessThan(less.frame.maxX, logo.frame.minX)
        less.tap()
        XCTAssertFalse(less.exists)
        XCTAssertTrue(more.exists)
    }

    @MainActor
    func testAutomationInventorySummaryAndDetailTables() {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-automation-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let card = app.buttons["automation-card.automation-0"]
        XCTAssertTrue(card.waitForExistence(timeout: 8), app.debugDescription)
        for fact in ["Daily workspace review", "Draft", "Every 1 day", "Server, Studio server", "Last run", "Updated", "Sep 1, 2026"] {
            XCTAssertTrue(card.label.contains(fact), "Missing \(fact): \(card.label)")
        }
        XCTAssertTrue(app.buttons["automation-card.automation-1"].label.contains("No runs yet"))
        let status = card.staticTexts["Draft"]
        let title = card.staticTexts["Daily workspace review"]
        XCTAssertTrue(status.exists)
        XCTAssertLessThanOrEqual(status.frame.minY, title.frame.minY + 8, "Status belongs in the top corner, not below the title")
        XCTAssertEqual(status.frame.maxX, card.frame.maxX - 14, accuracy: 2)
        XCTAssertLessThan(card.frame.height, 130, "Inline metadata should not recreate the tall divided card")
        keepScreenshot(named: "automation-inventory-summary-cards")
        card.tap()
        let summary = app.otherElements["automation-detail-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(summary.staticTexts["Daily workspace review"].exists, app.debugDescription)
        let detail = app.scrollViews.containing(.other, identifier: "automation-detail-summary").firstMatch
        let updated = summary.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Updated")).firstMatch
        XCTAssertTrue(updated.exists, app.debugDescription)
        XCTAssertTrue(updated.label.contains("Sep 20, 2026"), "Detail must use the newer record, not the selected catalog summary: \(updated.label)")
        XCTAssertEqual(detail.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Server,")).count, 1)
        let promptLabel = "Prompt, Review the workspace and summarize changes since the previous run. Do not modify files."
        XCTAssertTrue(app.staticTexts[promptLabel].exists, app.debugDescription)
        XCTAssertFalse(app.buttons[promptLabel].exists)
        keepScreenshot(named: "automation-detail-expanded-summary-and-tables")
        let recent = app.staticTexts["RECENT RUNS"]
        for _ in 0..<6 where !recent.isHittable { app.swipeUp() }
        XCTAssertTrue(recent.isHittable, app.debugDescription)
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.isHittable)
        XCTAssertLessThan(delete.frame.maxY, recent.frame.minY)
        keepScreenshot(named: "automation-detail-controls-before-history")
        let run = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Succeeded")).firstMatch
        XCTAssertTrue(run.isHittable, app.debugDescription)
        run.tap()
        XCTAssertTrue(app.staticTexts["Run Details"].waitForExistence(timeout: 5), app.debugDescription)
    }

    /// Archive and Unarchive follow Delete's flow: the swipe reveals the
    /// action, the tap asks for confirmation, and only the confirmation commits.
    /// The journey therefore proves that the revealed action alone changes
    /// nothing, then confirms.
    @MainActor
    private func swipeTapAndConfirm(
        _ row: XCUIElement,
        action identifier: String,
        in app: XCUIApplication,
        screenshot: String? = nil
    ) {
        row.swipeLeft()
        let action = app.buttons[identifier]
        XCTAssertTrue(action.waitForExistence(timeout: 5), app.debugDescription)
        action.tap()
        let confirm = app.buttons.matching(
            NSPredicate(format: "identifier IN %@", ["confirmation-primary-content", "confirmation-primary-toolbar"])
        ).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(row.exists, "The row must not move before the change is confirmed")
        if let screenshot { keepScreenshot(named: screenshot) }
        confirm.tap()
    }

    @MainActor
    func testSessionArchiveConfirmationAndArchivedContainerJourney() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-archive-fixture"]
        app.launch()
        defer { app.terminate() }

        let liveRow = app.buttons["session-row-fixture:live-session"]
        XCTAssertTrue(liveRow.waitForExistence(timeout: 8), app.debugDescription)
        // A zero archived count keeps the container off the dashboard.
        XCTAssertFalse(app.buttons["archived-sessions-container"].exists)

        swipeTapAndConfirm(
            liveRow,
            action: "session-archive-action-fixture:live-session",
            in: app,
            screenshot: "session-archive-confirmation"
        )

        let container = app.buttons["archived-sessions-container"]
        XCTAssertTrue(container.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(container.value as? String, "1")
        XCTAssertFalse(app.buttons["session-row-fixture:live-session"].exists)
        keepScreenshot(named: "session-archive-container-collapsed")

        container.tap()
        let archivedRow = app.buttons["archived-session-row-fixture:live-session"]
        XCTAssertTrue(archivedRow.waitForExistence(timeout: 5), app.debugDescription)
        keepScreenshot(named: "session-archive-container-expanded")

        swipeTapAndConfirm(archivedRow, action: "session-unarchive-action-fixture:live-session", in: app)

        // The count returns to zero, so the container hides and the session is
        // back among its workspace rows.
        XCTAssertTrue(app.buttons["session-row-fixture:live-session"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["archived-sessions-container"].waitForExistence(timeout: 2))
        keepScreenshot(named: "session-archive-unarchived")
    }

    /// The archived header is the dashboard's last section, so its rows publish
    /// below the fold. Expanding must move the list up until they are on screen,
    /// and the header's own icon is now the whole loading affordance: there is no
    /// placeholder row to show instead.
    @MainActor
    func testSessionArchiveExpansionRevealsRowsInView() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-archive-fixture", "-tron-session-archive-reveal-fixture"]
        app.launch()
        defer { app.terminate() }

        let container = app.buttons["archived-sessions-container"]
        // The list is much longer than the screen, so the header starts off screen
        // and the journey scrolls the dashboard to its end.
        XCTAssertFalse(container.isHittable, app.debugDescription)
        for _ in 0..<12 where !container.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(container.isHittable, app.debugDescription)
        XCTAssertGreaterThan(
            container.frame.minY,
            app.frame.midY,
            "The archived header must start at the bottom of the screen"
        )
        let headerMinYBeforeExpanding = container.frame.minY
        keepScreenshot(named: "session-archive-reveal-before")

        let firstRow = app.buttons["archived-session-row-fixture:archived-session-0"]
        container.tap()
        // The fixture gates its first page read, so the loading window is
        // observable: the header is expanded and no row has published yet. The
        // placeholder row this journey replaced never appears.
        XCTAssertFalse(firstRow.waitForExistence(timeout: 1), app.debugDescription)
        XCTAssertFalse(app.staticTexts["Loading archived sessions…"].exists, app.debugDescription)
        keepScreenshot(named: "session-archive-reveal-loading")

        XCTAssertTrue(firstRow.waitForExistence(timeout: 10), app.debugDescription)
        // The reveal is animated, so wait for the row to be inside the visible
        // frame rather than sampling the scroll the moment it publishes.
        let rowIsVisible = NSPredicate { element, _ in
            guard let element = element as? XCUIElement else { return false }
            return element.isHittable
        }
        expectation(for: rowIsVisible, evaluatedWith: firstRow)
        waitForExpectations(timeout: 10)

        // The list moved up to make room: the revealed rows are in view, the
        // header is still visible and above its pre-expansion position, and the
        // section's own rows sit below it.
        XCTAssertLessThan(container.frame.minY, headerMinYBeforeExpanding, app.debugDescription)
        XCTAssertTrue(container.isHittable, app.debugDescription)
        XCTAssertGreaterThan(firstRow.frame.minY, container.frame.minY, app.debugDescription)
        // The revealed row is inside the usable area, not peeking past the
        // bottom edge behind the home indicator.
        XCTAssertLessThan(
            firstRow.frame.maxY,
            app.frame.maxY - 40,
            "The revealed row must be fully on screen"
        )
        XCTAssertFalse(app.staticTexts["Loading archived sessions…"].exists, app.debugDescription)
        keepScreenshot(named: "session-archive-reveal-after")
    }

    @MainActor
    func testSessionArchivePagingRetiresInFlightPassAndRestartsRefusedCursor() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-archive-fixture", "-tron-session-archive-paging-fixture"]
        app.launch()
        defer { app.terminate() }

        let liveRow = app.buttons["session-row-fixture:live-session"]
        XCTAssertTrue(liveRow.waitForExistence(timeout: 8), app.debugDescription)
        let container = app.buttons["archived-sessions-container"]
        XCTAssertTrue(container.waitForExistence(timeout: 5), app.debugDescription)
        // The fixture serves one archived session per page, so the first pass
        // both populates the container and offers Show more.
        XCTAssertEqual(container.value as? String, "1", app.debugDescription)

        // Expanding starts the pass whose first read hangs. Archiving the live
        // row then advances the archive projection while that read is still in
        // flight, which is exactly the reload that a dropped pass would lose.
        container.tap()
        swipeTapAndConfirm(liveRow, action: "session-archive-action-fixture:live-session", in: app)

        let archivedLiveRow = app.buttons["archived-session-row-fixture:live-session"]
        XCTAssertTrue(archivedLiveRow.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["archived-session-row-fixture:older-session"].exists, app.debugDescription)

        // A continuation the Gateway refuses is replaced by that server's first
        // page: the rows stay, and no server is reported unavailable. The
        // control's label carries the section it expands.
        let showMore = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Show more")).firstMatch
        XCTAssertTrue(showMore.waitForExistence(timeout: 5), app.debugDescription)
        showMore.tap()
        XCTAssertTrue(archivedLiveRow.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(showMore.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Archived sessions unavailable"))
                .firstMatch.exists,
            app.debugDescription
        )
        keepScreenshot(named: "session-archive-paging-restart")
    }

    @MainActor
    func testAskUserOtherEditorExpandsMediumSheetAndOpensKeyboard() {
        let app = launchAskUser()
        waitForAskUserForm(in: app)
        let close = app.buttons["Close form and keep answers"]
        let mediumY = close.frame.minY
        XCTAssertGreaterThan(mediumY, app.frame.height * 0.4)
        app.buttons["Staging"].tap()
        app.buttons["Other"].tap()
        let editor = app.textViews["Other response for Environment"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertEqual(close.frame.minY, mediumY, accuracy: 2, "Revealing Other must not focus an unmounted editor")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        keepScreenshot(named: "ask-user-other-editor-medium")
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        let expanded = NSPredicate { element, _ in
            guard let element = element as? XCUIElement else { return false }
            return element.frame.minY < mediumY - 100
        }
        expectation(for: expanded, evaluatedWith: close)
        waitForExpectations(timeout: 5)
        editor.typeText("First line\nSecond line")
        XCTAssertEqual(editor.value as? String, "First line\nSecond line")
        keepScreenshot(named: "ask-user-other-editor-large-keyboard")
        app.buttons["Other"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertEqual(app.buttons["Staging"].value as? String, "Selected")
        app.buttons["Other"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertEqual(editor.value as? String, "")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        app.buttons["Close form and keep answers"].tap()
        XCTAssertTrue(app.staticTexts["Mutation count: 0"].waitForExistence(timeout: 3))
    }

    /// Failure mode: Send on a paged single-choice form while the last page's
    /// Other editor holds the keyboard hangs the app before the answer is sent.
    @MainActor
    func testAskUserSendWithFocusedOtherEditorOnLastPageSubmits() {
        let app = launchAskUser(styled: true, multiple: true)
        let staging = app.buttons["Staging, A pre-release environment for validation."]
        XCTAssertTrue(staging.waitForExistence(timeout: 5), app.debugDescription)
        staging.tap()
        app.staticTexts["Which environments should receive the change?"].swipeLeft()
        XCTAssertTrue(app.staticTexts["When should the change happen?"].waitForExistence(timeout: 3), app.debugDescription)
        let other = app.buttons.matching(NSPredicate(format: "label == %@", "Other"))
            .allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(other, app.debugDescription)
        other?.tap()
        let editor = app.textViews["Other response for When should the change happen?"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3), app.debugDescription)
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        editor.typeText("After the review")
        keepScreenshot(named: "ask-user-last-page-other-focused")
        app.buttons["Submit all answers"].tap()
        XCTAssertTrue(app.staticTexts["Mutation count: 1"].waitForExistence(timeout: 10), app.debugDescription)
        keepScreenshot(named: "ask-user-last-page-other-submitted")
    }

    @MainActor
    func testAskUserSingleChoiceOtherEditorHidesWhenChoosingAnOption() {
        let app = launchAskUser(styled: true)
        let close = app.buttons["Close form and keep answers"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        let mediumY = close.frame.minY
        XCTAssertGreaterThan(mediumY, app.frame.height * 0.4)
        app.buttons["Other"].tap()
        let editor = app.textViews["Other response for Environment"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertEqual(close.frame.minY, mediumY, accuracy: 2)
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertLessThan(close.frame.minY, mediumY - 100)
        editor.typeText("A custom environment")
        app.buttons["Staging, A pre-release environment for validation."].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Submit all answers"].isEnabled)
        keepScreenshot(named: "ask-user-other-editor-hidden-single-choice")
    }

    @MainActor
    func testAskUserClosePreservesSelectionsAndOtherDraftOnReopen() {
        let app = launchAskUser()
        waitForAskUserForm(in: app)
        app.buttons["Staging"].tap()
        app.buttons["Other"].tap()
        let other = app.textViews["Other response for Environment"]
        XCTAssertTrue(other.waitForExistence(timeout: 3))
        other.tap()
        other.typeText("local canary")
        app.buttons["Close form and keep answers"].tap()
        XCTAssertTrue(app.buttons["Reopen Ask User"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Mutation count: 0"].exists)
        app.buttons["Reopen Ask User"].tap()
        XCTAssertTrue(app.buttons["Staging"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["Staging"].value as? String, "Selected")
        let restored = app.textViews["Other response for Environment"]
        XCTAssertTrue(restored.waitForExistence(timeout: 3))
        restored.tap()
        app.buttons["Submit all answers"].tap()
        XCTAssertTrue(app.staticTexts["Mutation count: 1"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["extension.respond cancelled=false selected=environment-a other=local canary"].exists)
    }

    @MainActor
    func testAskUserWithoutAllowCancelHasCloseOnly() {
        let app = launchAskUser(noCancel: true)
        waitForAskUserForm(in: app)
        XCTAssertFalse(app.buttons["Cancel form"].exists)
        XCTAssertTrue(app.buttons["Close form and keep answers"].exists)
        app.buttons["Close form and keep answers"].tap()
        XCTAssertTrue(app.staticTexts["Mutation count: 0"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["Reopen Ask User"].exists)
    }

    @MainActor
    func testAskUserSubmitRendersExactReadOnlyCompletedForm() {
        let app = launchAskUser()
        waitForAskUserForm(in: app)
        app.buttons["Staging"].tap()
        app.buttons["Production"].tap()
        app.buttons["Other"].tap()
        let other = app.textViews["Other response for Environment"]
        XCTAssertTrue(other.waitForExistence(timeout: 3))
        other.tap()
        other.typeText("A canary region")
        app.buttons["Submit all answers"].tap()
        XCTAssertTrue(app.staticTexts["Choose deployment target"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Other"].exists)
        XCTAssertTrue(app.staticTexts["A canary region"].exists)
        XCTAssertTrue(app.staticTexts["Mutation count: 1"].exists)
        XCTAssertTrue(app.staticTexts["extension.respond cancelled=false selected=environment-a,environment-b other=A canary region"].exists)
        XCTAssertFalse(app.textViews["Other response for Environment"].exists)
        keepScreenshot(named: "ask-user-completed-read-only-fixture")
    }

    @MainActor
    func testAskUserInstructionAndSeparateToolbarLayout() {
        let app = launchAskUser(styled: true)
        let question = app.staticTexts["Which environments should receive the change?"]
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        let instruction = app.staticTexts["Select one. Question 1 of 1"]
        let option = app.buttons["Staging, A pre-release environment for validation."]
        XCTAssertTrue(instruction.exists)
        XCTAssertTrue(option.exists)
        XCTAssertLessThanOrEqual(instruction.frame.maxY, question.frame.minY)
        XCTAssertLessThanOrEqual(question.frame.maxY, option.frame.minY)
        let close = app.buttons["Close form and keep answers"]
        let cancel = app.buttons["Cancel form"]
        XCTAssertTrue(close.isHittable)
        XCTAssertTrue(cancel.isHittable)
        XCTAssertLessThan(cancel.frame.maxX, close.frame.minX)
        XCTAssertLessThanOrEqual(close.frame.maxX, app.buttons["Submit all answers"].frame.minX)
        XCTAssertFalse(app.buttons["Submit all answers"].isEnabled)
        keepScreenshot(named: "ask-user-styled-active-disabled")
        option.tap()
        XCTAssertTrue(app.buttons["Submit all answers"].isEnabled)
        keepScreenshot(named: "ask-user-styled-active-selected")
    }

    @MainActor
    private func launchAskUser(noCancel: Bool = false, styled: Bool = false, multiple: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-ask-user-fixture"]
        if noCancel { app.launchArguments.append("-tron-ask-user-no-cancel") }
        if styled { app.launchArguments.append("-tron-ask-user-styled") }
        if multiple { app.launchArguments.append("-tron-ask-user-multiple") }
        app.launch()
        return app
    }

    @MainActor
    private func waitForAskUserForm(in app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Choose deployment target"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["Staging"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.buttons["Production"].exists)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "ask-user-form-fixture"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func assertWelcomeVisualParity() {
        guard let referenceURL = Bundle(for: Self.self).url(
            forResource: "onboarding-welcome-medium-historical",
            withExtension: "png"
        ), let reference = UIImage(contentsOfFile: referenceURL.path)?.cgImage,
           let current = XCUIScreen.main.screenshot().image.cgImage else {
            return XCTFail("Historical onboarding visual reference is missing")
        }
        // The executable historical artifact is an iPhone 17 Pro baseline.
        // Larger physical devices retain geometry assertions and screenshots,
        // but must not be resampled into a misleading feature-print comparison.
        guard reference.width == current.width, reference.height == current.height else { return }
        let crop = CGRect(x: 0, y: 1242, width: 1206, height: 1380)
        guard let referenceCrop = reference.cropping(to: crop),
              let currentCrop = current.cropping(to: crop) else {
            return XCTFail("Onboarding screenshots must retain the iPhone 17 Pro reference dimensions")
        }
        do {
            let historical = try featurePrint(referenceCrop)
            let rendered = try featurePrint(currentCrop)
            var distance: Float = 0
            try historical.computeDistance(&distance, to: rendered)
            XCTAssertLessThan(distance, 0.38, "Medium onboarding sheet drifted from the executable historical baseline")
        } catch {
            XCTFail("Could not compare onboarding visuals: \(error)")
        }
    }

    private func featurePrint(_ image: CGImage) throws -> VNFeaturePrintObservation {
        let request = VNGenerateImageFeaturePrintRequest()
        if let cpu = MLComputeDevice.allComputeDevices.first(where: {
            if case .cpu = $0 { return true }
            return false
        }) {
            for (stage, devices) in try request.supportedComputeStageDevices where devices.contains(cpu) {
                request.setComputeDevice(cpu, for: stage)
            }
        }
        try VNImageRequestHandler(cgImage: image).perform([request])
        guard let observation = request.results?.first as? VNFeaturePrintObservation else {
            throw VisualParityFailure.noFeaturePrint
        }
        return observation
    }

    private enum VisualParityFailure: Error { case noFeaturePrint }

    @MainActor
    private func keepScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func assertAccessibilityAuditPasses(_ app: XCUIApplication) {
        var failures: [String] = []
        XCTAssertNoThrow(try app.performAccessibilityAudit { issue in
            let element = issue.element
            // XCTest predicts clipping from the field's normal-size UIKit host
            // frame without rerunning SwiftUI layout. The dedicated XXXL test
            // above relaunches and verifies the real custom field grows.
            if issue.auditType == .textClipped,
               element?.label == "Tailscale host",
               element?.elementType == .textField { return true }
            failures.append("\(issue.compactDescription): \(issue.detailedDescription) [label=\(element?.label ?? "nil"), id=\(element?.identifier ?? "nil"), frame=\(String(describing: element?.frame)), element=\(element?.debugDescription ?? "nil")]")
            return true
        })
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    @MainActor
    private func launchResetApp(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--tron-reset-ui-test-state", "-ApplePersistenceIgnoreState", "YES"] + extraArguments
        app.launch()
        return app
    }
}
