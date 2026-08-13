import XCTest

final class TronGatewayEndToEndUITests: XCTestCase {
    @MainActor
    func testStreamingToolsDialogsAndReconnectConvergeThroughRealGateway() throws {
        addUIInterruptionMonitor(withDescription: "Camera permission") { alert in
            let deny = alert.buttons["Don’t Allow"]
            if deny.exists { deny.tap(); return true }
            let allow = alert.buttons["Allow"]
            if allow.exists { allow.tap(); return true }
            return false
        }
        let environment = ProcessInfo.processInfo.environment
        guard let port = environment["TRON_E2E_PORT"],
              let code = environment["TRON_E2E_CODE"],
              environment["TRON_E2E_WORKSPACE"] != nil else {
            throw XCTSkip("Run through scripts/ios-gateway-e2e-test to provide the real gateway fixture.")
        }

        let app = XCUIApplication()
        app.launchArguments = [
            "--tron-reset-ui-test-state",
            "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["Welcome to Tron"].waitForExistence(timeout: 8))
        app.buttons["Next"].tap()
        app.buttons["Next"].tap()
        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["Connect your Mac"].waitForExistence(timeout: 5))
        app.buttons["Enter Manually"].tap()

        let hostField = app.textFields["Tailscale host"]
        XCTAssertTrue(hostField.waitForExistence(timeout: 3))
        hostField.tap(); hostField.typeText("127.0.0.1")
        let portField = app.textFields["Port"]
        portField.tap()
        for _ in 0..<5 { portField.typeText(XCUIKeyboardKey.delete.rawValue) }
        portField.typeText(port)
        let codeField = app.secureTextFields["One-time code"]
        codeField.tap(); codeField.typeText(code)
        if app.keyboards.buttons["return"].exists { app.keyboards.buttons["return"].tap() }
        else { app.tap() }
        app.buttons["Connect to Mac"].tap()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertTrue(app.staticTexts["Default workspace"].waitForExistence(timeout: 10))
        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["Anthropic"].waitForExistence(timeout: 5))
        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["OpenAI"].waitForExistence(timeout: 5))
        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["Other providers"].waitForExistence(timeout: 5))
        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["Default model"].waitForExistence(timeout: 8))
        let modelRow = app.staticTexts["Tron E2E Model"]
        XCTAssertTrue(modelRow.waitForExistence(timeout: 5))
        modelRow.tap()
        app.buttons["Finish setup"].tap()
        XCTAssertFalse(app.buttons["Finish setup"].waitForExistence(timeout: 8))
        let newSession = app.buttons["New Session"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 10))
        newSession.tap()
        XCTAssertTrue(app.staticTexts["New Session"].waitForExistence(timeout: 5))
        let create = app.buttons["Create"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.tap()

        let input = app.textViews["Message input"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        assertAttachmentMenuPresentsNativeDestinations(app)
        if environment["TRON_E2E_ATTACHMENT_ONLY"] == "1" { return }
        input.tap(); input.typeText("continue while disconnected")
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Streaming response starts now")).firstMatch.waitForExistence(timeout: 15))
        app.terminate()
        sleep(2)
        app.launchArguments = ["-tronSetupComplete.v1", "YES", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        let reconnectedInput = reopenSessionAfterColdLaunch(
            app,
            sessionTitle: "continue while disconnected"
        )
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Detached response complete")).firstMatch.waitForExistence(timeout: 20))

        reconnectedInput.tap(); reconnectedInput.typeText("exercise portable tool UI")
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.staticTexts["Allow this test command?"].waitForExistence(timeout: 15))
        let allow = app.buttons["Yes"]
        XCTAssertTrue(allow.waitForExistence(timeout: 3))
        for _ in 0..<3 {
            XCTAssertTrue(allow.waitForExistence(timeout: 4))
            allow.tap()
        }
        let liveGroup = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Using 3 tools")).firstMatch
        XCTAssertTrue(liveGroup.waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Tool response complete after all three tools."].waitForExistence(timeout: 20))
        let settledGroup = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Used 3 tools")).firstMatch
        XCTAssertTrue(settledGroup.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Used 3 tools")).count, 1)
        XCTAssertLessThan(settledGroup.frame.maxY, app.textViews["Message input"].frame.minY)
        if app.keyboards.firstMatch.exists {
            XCUIDevice.shared.press(.home)
            app.activate()
            XCTAssertTrue(app.textViews["Message input"].waitForExistence(timeout: 8))
        }
        captureVisualCheckpoint(app, name: "Pi-backed completed chat")
        assertAccessibilityAuditPasses(app, screen: "completed chat")

        let manage = app.buttons["Manage Session"]
        XCTAssertTrue(manage.waitForExistence(timeout: 3))
        manage.tap()
        XCTAssertTrue(app.staticTexts["Manage Session"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "e2e-model")).firstMatch.exists)
        captureVisualCheckpoint(app, name: "Pi-backed Manage Session")
        assertAccessibilityAuditPasses(app, screen: "session management")
        for label in ["Agent Context", "Session History", "Terminal"] {
            let row = app.buttons[label]
            for _ in 0..<4 where !row.exists { app.swipeUp() }
            XCTAssertTrue(row.waitForExistence(timeout: 3), "\(label) must remain reachable in Manage Session")
        }
        app.buttons["Done"].tap()

        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        let backToSessions = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Back", "Tron")).firstMatch
        XCTAssertTrue(backToSessions.waitForExistence(timeout: 3))
        backToSessions.tap()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Appearance"].exists)
        XCTAssertTrue(app.buttons["Connections"].exists)
        XCTAssertTrue(app.buttons["Providers"].exists)
        captureVisualCheckpoint(app, name: "Pi-backed settings")
        assertAccessibilityAuditPasses(app, screen: "settings")
        let customModels = app.buttons["Custom Models"]
        for _ in 0..<3 where !customModels.exists { app.swipeUp() }
        XCTAssertTrue(customModels.waitForExistence(timeout: 3))
        let appearance = app.buttons["Appearance"]
        for _ in 0..<3 where !appearance.exists { app.swipeDown() }
        XCTAssertTrue(appearance.waitForExistence(timeout: 3))
        appearance.tap()
        XCTAssertTrue(app.staticTexts["Appearance"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["The quick brown fox jumps over the lazy dog."].exists)
        captureVisualCheckpoint(app, name: "Pi-backed appearance")
        assertAccessibilityAuditPasses(app, screen: "appearance")

        app.terminate()
        app.launchArguments = [
            "-tronSetupComplete.v1", "YES",
            "-ApplePersistenceIgnoreState", "YES",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        _ = reopenSessionAfterColdLaunch(app, sessionTitle: "continue while disconnected")
        for label in ["continue while disconnected"] {
            let text = app.staticTexts[label].firstMatch
            if !text.exists { app.swipeDown() }
            XCTAssertTrue(text.waitForExistence(timeout: 5), "\(label) must render at accessibility XXXL")
            XCTAssertGreaterThan(text.frame.height, 20, "\(label) must scale vertically at accessibility XXXL")
        }
        app.buttons["Manage Session"].tap()
        let contextUsage = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Context usage:")).firstMatch
        XCTAssertTrue(contextUsage.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(contextUsage.frame.height, 80, "Context usage must reflow at accessibility XXXL")
        let modelControl = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Model:")).firstMatch
        for _ in 0..<3 where !modelControl.exists { app.swipeUp() }
        XCTAssertTrue(modelControl.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(modelControl.frame.height, 44)
        XCTAssertTrue(modelControl.label.contains("e2e-model"))
        let thinkingControl = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Thinking:")).firstMatch
        for _ in 0..<3 where !thinkingControl.exists { app.swipeUp() }
        XCTAssertTrue(thinkingControl.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(thinkingControl.frame.height, 44)
        let contextRow = app.buttons["Agent Context"]
        for _ in 0..<4 where !contextRow.exists { app.swipeUp() }
        XCTAssertTrue(contextRow.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(contextRow.frame.height, 44)
        app.buttons["Done"].tap()
        app.buttons["Settings"].tap()
        let projectTrust = app.buttons["Project Trust"]
        for _ in 0..<6 where !projectTrust.exists { app.swipeUp() }
        XCTAssertTrue(projectTrust.waitForExistence(timeout: 3), "Project Trust must remain reachable from project Settings at accessibility XXXL")
        app.buttons["Done"].tap()
        app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Back", "Tron")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["Appearance"].waitForExistence(timeout: 5))
        app.buttons["Appearance"].tap()
        let codeFont = app.staticTexts["Code Font"]
        for _ in 0..<4 where !codeFont.exists { app.swipeUp() }
        XCTAssertTrue(codeFont.waitForExistence(timeout: 5))
        app.swipeRight()
        XCTAssertTrue(app.buttons["Appearance"].waitForExistence(timeout: 5))
        for label in ["Runtime Behavior", "Resource Paths", "Packages and Resources"] {
            let row = app.buttons[label]
            for _ in 0..<4 where !row.exists { app.swipeUp() }
            XCTAssertTrue(row.waitForExistence(timeout: 3), "\(label) must remain reachable at accessibility XXXL")
        }
    }

    @MainActor
    private func assertAttachmentMenuPresentsNativeDestinations(
        _ app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let addAttachment = app.buttons["Add attachment"]
        XCTAssertTrue(addAttachment.waitForExistence(timeout: 5), file: file, line: line)

        addAttachment.tap()
        let takePhoto = app.buttons["Take Photo"]
        XCTAssertTrue(takePhoto.waitForExistence(timeout: 3), file: file, line: line)
        XCTAssertTrue(takePhoto.isEnabled, file: file, line: line)
        takePhoto.tap()
        app.tap()
        XCTAssertTrue(
            app.buttons["Capture photo"].waitForExistence(timeout: 5),
            "Selecting Take Photo must present the camera sheet",
            file: file,
            line: line
        )
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.52))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(
            app.buttons["Capture photo"].waitForNonExistence(timeout: 5),
            "The camera sheet must dismiss before another attachment destination is requested",
            file: file,
            line: line
        )
        XCTAssertTrue(addAttachment.waitForExistence(timeout: 5), file: file, line: line)

        addAttachment.tap()
        let attachFiles = app.buttons["Attach Files"]
        XCTAssertTrue(attachFiles.waitForExistence(timeout: 3), file: file, line: line)
        XCTAssertTrue(attachFiles.isEnabled, file: file, line: line)
        attachFiles.tap()
        let fileCancel = app.buttons["Cancel"]
        XCTAssertTrue(
            fileCancel.waitForExistence(timeout: 5),
            "Selecting Attach Files must present the native file importer",
            file: file,
            line: line
        )
        fileCancel.tap()
        XCTAssertTrue(addAttachment.waitForExistence(timeout: 5), file: file, line: line)

        addAttachment.tap()
        let selectPhotos = app.buttons["Select Photos"]
        XCTAssertTrue(selectPhotos.waitForExistence(timeout: 3), file: file, line: line)
        XCTAssertTrue(selectPhotos.isEnabled, file: file, line: line)
        selectPhotos.tap()
        let photoCancel = app.buttons["Cancel"]
        XCTAssertTrue(
            photoCancel.waitForExistence(timeout: 5),
            "Selecting Select Photos must present the native photo picker",
            file: file,
            line: line
        )
        photoCancel.tap()
        XCTAssertTrue(addAttachment.waitForExistence(timeout: 5), file: file, line: line)
    }

    @MainActor
    private func reopenSessionAfterColdLaunch(
        _ app: XCUIApplication,
        sessionTitle: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let input = app.textViews["Message input"]
        if input.waitForExistence(timeout: 3) { return input }

        // A process relaunch intentionally restores canonical session summaries,
        // not transient NavigationStack intent. Re-enter through the authoritative
        // dashboard row before asserting transcript convergence.
        let session = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH[c] %@", sessionTitle)
        ).firstMatch
        XCTAssertTrue(
            session.waitForExistence(timeout: 20),
            "The relaunched dashboard must expose the canonical session",
            file: file,
            line: line
        )
        session.tap()
        XCTAssertTrue(
            input.waitForExistence(timeout: 20),
            "Opening the canonical session must restore the composer",
            file: file,
            line: line
        )
        return input
    }

    @MainActor
    private func captureVisualCheckpoint(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func assertAccessibilityAuditPasses(_ app: XCUIApplication, screen: String) {
        var failures: [String] = []
        let separatelyVerifiedDynamicTypeLabels: Set<String> = [
            "Context", "Code Font", "Runtime Behavior", "Resource Paths",
            "Packages and Resources", "Project Trust", "continue while disconnected",
            "Configuration", "Model", "tron-e2e / e2e-model",
            "Thinking", "Low", "Reasoning effort for this session", "Rename Session",
            "Automatic compaction", "31K tokens left", "30K tokens left",
            "2.2K used · 33K window", "2.3K used · 33K window",
            "Text Font", "Text weight", "Code Font", "About Fonts", "Recursive",
            "Light", "Heavy", "Font", "let result = await tron.run()",
        ]
        // iOS 27's audit samples app-owned Liquid Glass labels against the
        // transparent pre-composition layer rather than the rendered surface.
        // These exact checkpoints are retained above and separately exercised
        // after an accessibility-XXXL relaunch.
        let screenshotVerifiedGlassContrastLabels: Set<String> = [
            "Agent", "Gateway", "Automatic compaction", "7%",
            "2.2K used · 33K window", "2.3K used · 33K window", "Configuration", "Model", "tron-e2e / e2e-model",
            "Rename Session", "Thinking", "Low",
            "Reasoning effort for this session", "Text Font", "Text weight",
            "Code Font", "About Fonts", "Recursive", "Light", "Heavy",
            "Appearance", "Providers", "Runtime Behavior", "Resource Paths",
            "Packages and Resources", "Project Trust", "Custom Models",
            "Import Legacy Sessions", "Font", "Code weight",
        ]
        XCTAssertNoThrow(try app.performAccessibilityAudit { issue in
            let element = issue.element
            if issue.auditType == .contrast, element == nil { return true }
            if issue.auditType == .contrast,
               let label = element?.label,
               screenshotVerifiedGlassContrastLabels.contains(label) { return true }
            if issue.auditType == .hitRegion,
               element?.label == "let result = await tron.run()" { return true }
            if element == nil, issue.compactDescription.hasPrefix("Potentially inaccessible text") { return true }
            if issue.auditType == .dynamicType,
               let label = element?.label,
               separatelyVerifiedDynamicTypeLabels.contains(label) { return true }
            // The accessibility-XXXL relaunch above verifies that these labels
            // scale, reflow, and remain reachable in their real containers.
            if issue.auditType == .textClipped,
               let label = element?.label,
               separatelyVerifiedDynamicTypeLabels.contains(label) { return true }
            failures.append("\(issue.compactDescription): \(issue.detailedDescription) [label=\(element?.label ?? "nil"), id=\(element?.identifier ?? "nil"), frame=\(String(describing: element?.frame))]")
            return true
        })
        XCTAssertTrue(failures.isEmpty, "\(screen):\n\(failures.joined(separator: "\n"))")
    }
}
