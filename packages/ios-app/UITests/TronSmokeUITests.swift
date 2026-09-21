import CoreML
import UIKit
import Vision
import XCTest

final class TronSmokeUITests: XCTestCase {
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
            XCTAssertTrue(app.buttons["Runtime Behavior"].waitForExistence(timeout: 3))
            app.terminate()
        }
    }

    @MainActor
    func testRuntimeBehaviorThinkingSliderOpensAfterDefaultsConsolidation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-runtime-settings-fixture"]
        app.launch()
        defer { app.terminate() }
        let control = app.buttons.matching(identifier: "thinking-level-control")
            .matching(NSPredicate(format: "label == %@", "Thinking")).firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        XCTAssertTrue(control.isEnabled)
        control.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "thinking-level-slider").firstMatch.waitForExistence(timeout: 3))
        keepScreenshot(named: "runtime-behavior-thinking-editor-fixture")
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
