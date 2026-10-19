import XCTest

/// Bounded UI-first review capture, not behavioral acceptance of replay or
/// Gateway persistence. The follow-up real-Gateway journey owns that proof.
final class TronToolSheetsPolishUITests: XCTestCase {
    @MainActor func testCaptureLightAndDarkReviewSurfaces() {
        continueAfterFailure = false
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            for scenario in ["ask", "search", "delegate", "context-long", "context-short", "prompt", "short-prompt"] {
                let app = XCUIApplication()
                app.launchArguments = ["-tron-tool-sheets-polish-fixture", "-polish-scenario", scenario,
                                       dark ? "-polish-dark" : "-polish-light", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
                app.launch()
                XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
                // Wait for the actual sheet or rendered prompt before capturing.
                if scenario == "prompt" || scenario == "short-prompt" {
                    XCTAssertTrue(app.staticTexts["Transcript presentation review"].waitForExistence(timeout: 10))
                } else {
                    XCTAssertTrue(app.buttons["Done"].firstMatch.waitForExistence(timeout: 10))
                }
                capture(app, "\(scenario)-\(mode)")
                if scenario == "delegate" {
                    app.swipeUp()
                    capture(app, "delegate-models-\(mode)")
                }
                if scenario == "prompt" {
                    let prompt = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Fix: attaching photos'")).firstMatch
                    XCTAssertTrue(prompt.waitForExistence(timeout: 5), app.debugDescription)
                    prompt.tap()
                    XCTAssertTrue(app.staticTexts["Prompt"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
                    capture(app, "prompt-full-content-\(mode)")
                }
                app.terminate()
            }
            let app = XCUIApplication()
            app.launchArguments = ["-tron-chat-display-fixture", "-chat-display-inline-group",
                                   dark ? "-polish-dark" : "-polish-light", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()
            let first = app.buttons["Open Home dashboard after the fix photo preview"]
            XCTAssertTrue(first.waitForExistence(timeout: 25), app.debugDescription)
            capture(app, "display-inline-\(mode)")
            first.tap()
            XCTAssertTrue(app.buttons["Technical details"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
            capture(app, "display-preview-\(mode)")
            app.terminate()
        }
    }

    /// Approval evidence only; interaction/receipt acceptance runs after review.
    @MainActor func testCaptureHomeSecondaryRowsForReview() {
        continueAfterFailure = false
        for mode in ["light", "dark"] {
            for large in [false, true] {
                for scenario in ["task", "delegate", "search"] {
                    let app = XCUIApplication()
                    app.launchArguments = ["-tron-tool-sheets-polish-fixture", "-polish-scenario", scenario,
                                           "-polish-\(mode)", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
                    if large {
                        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
                    }
                    app.launch()
                    XCTAssertTrue(app.buttons["Technical details"].waitForExistence(timeout: 15), app.debugDescription)
                    let content = scenario == "search" ? "session-search-tool-detail" : "home-tool-detail"
                    XCTAssertTrue(app.descendants(matching: .any)[content].exists, app.debugDescription)
                    let suffix = "\(mode)-\(large ? "accessibility" : "standard")"
                    capture(app, "1318-\(scenario)-\(suffix)")
                    app.swipeUp()
                    capture(app, "1318-\(scenario)-lower-\(suffix)")
                    app.terminate()
                }
            }
        }
    }

    /// Preview plus a focused native-reader round trip; no live task is sent.
    @MainActor func testTaskMessageHeaderAndFullReaderForReview() {
        continueAfterFailure = false
        for mode in ["light", "dark"] {
            for large in [false, true] {
                let app = XCUIApplication()
                app.launchArguments = ["-tron-tool-sheets-polish-fixture", "-polish-scenario", "task-message", "-polish-\(mode)"]
                if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
                app.launch()
                let detail = app.descendants(matching: .any)["home-tool-detail"]
                XCTAssertTrue(detail.waitForExistence(timeout: 15))
                XCTAssertFalse(detail.descendants(matching: .any)["home-tool-row-Task ID"].exists)
                let delivery = app.staticTexts["Message (Delivered to the worker's running operation.)"]
                XCTAssertTrue(delivery.exists, app.debugDescription)
                let suffix = "\(mode)-\(large ? "large" : "standard")"
                capture(app, "1325-task-message-\(suffix)")
                let reader = app.buttons["home-tool-text-message-view-all"]
                for _ in 0..<12 where !reader.isHittable { app.swipeUp() }
                XCTAssertTrue(reader.isHittable)
                XCTAssertEqual(reader.label, "View full message")
                reader.tap()
                XCTAssertTrue(app.descendants(matching: .any)["home-reading-text"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Wait for visual approval")).firstMatch.exists)
                capture(app, "1325-task-full-message-\(suffix)")
                let done = app.buttons.matching(NSPredicate(format: "label == %@", "Done")).allElementsBoundByIndex.last { $0.isHittable }
                XCTAssertNotNil(done, app.debugDescription)
                done?.tap()
                XCTAssertTrue(delivery.waitForExistence(timeout: 5), "Closing the reader returns to the same delivery summary")
                XCTAssertTrue(detail.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "photo-readiness")).firstMatch.exists)
                app.terminate()
            }
        }
    }

    @MainActor func testTaskResumeStopAndNoMessageKeepIdentityAndReaderOwnership() {
        continueAfterFailure = false
        for (scenario, expected) in [
            ("task-resume-message", "Instruction (The task continues in place in its worker session.)"),
            ("task-stop-message", "Message (Stop recorded for this exact operation.)"),
            ("task-stop-empty", "Stop recorded for this exact operation.")
        ] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-tool-sheets-polish-fixture", "-polish-scenario", scenario]
            app.launch(); defer { app.terminate() }
            let detail = app.descendants(matching: .any)["home-tool-detail"]
            XCTAssertTrue(detail.waitForExistence(timeout: 15))
            XCTAssertFalse(detail.descendants(matching: .any)["home-tool-row-Task ID"].exists)
            XCTAssertTrue(detail.descendants(matching: .any)["home-tool-header"].descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", "photo-readiness")).firstMatch.exists)
            let delivery = app.staticTexts[expected]
            XCTAssertTrue(delivery.exists, app.debugDescription)
            let reader = app.buttons["home-tool-text-message-view-all"]
            if scenario == "task-stop-empty" {
                XCTAssertFalse(reader.exists)
                XCTAssertFalse(detail.descendants(matching: .any)["home-tool-text-message"].exists)
            } else {
                for _ in 0..<12 where !reader.isHittable { app.swipeUp() }
                XCTAssertEqual(reader.label, "View full message")
                reader.tap()
                XCTAssertTrue(app.descendants(matching: .any)["home-reading-text"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Wait for visual approval")).firstMatch.exists)
                let done = app.buttons.matching(NSPredicate(format: "label == %@", "Done")).allElementsBoundByIndex.last { $0.isHittable }
                XCTAssertNotNil(done); done?.tap()
                XCTAssertTrue(delivery.waitForExistence(timeout: 5))
            }
            capture(app, "1325-" + scenario)
        }
    }

    @MainActor func testOnlyOverflowingPromptOpensFullMarkdownReader() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-tool-sheets-polish-fixture", "-polish-scenario", "prompt", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let prompt = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Fix: attaching photos'")).firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertLessThan(prompt.frame.height, app.windows.firstMatch.frame.height, "The long prompt has a bounded viewport")
        prompt.tap()
        let reader = app.descendants(matching: .any)["home-reading-text"]
        XCTAssertTrue(reader.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Prompt"].exists)
        let tail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Wait for visual approval before behavioral regression runs or merging.")).firstMatch
        for _ in 0..<8 where !tail.isHittable { app.swipeUp() }
        XCTAssertTrue(tail.isHittable, "The reader must expose the original text beyond the truncated viewport")
        capture(app, "1302-full-prompt-reader-tail")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(reader.waitForNonExistence(timeout: 10))
        app.terminate()
        app.launchArguments = ["-tron-tool-sheets-polish-fixture", "-polish-scenario", "short-prompt", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let short = app.staticTexts["Please inspect the selected photos and keep the current layout."]
        XCTAssertTrue(short.waitForExistence(timeout: 15), app.debugDescription)
        short.tap()
        XCTAssertFalse(reader.exists, "An untruncated prompt must not acquire a detail-sheet action")
        XCTAssertFalse(app.staticTexts["Prompt"].exists)
        short.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 5), "The short prompt retains its original context menu")
        XCTAssertFalse(reader.exists, "Long press must not open the prompt reader")
    }

    @MainActor func testSearchAndDelegateSeparateReadableContentFromTechnicalPayloads() {
        continueAfterFailure = false
        let app = XCUIApplication()
        defer { app.terminate() }
        for scenario in ["search", "delegate"] {
            app.launchArguments = ["-tron-tool-sheets-polish-fixture", "-polish-scenario", scenario, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()
            let info = app.buttons["Technical details"]
            XCTAssertTrue(info.waitForExistence(timeout: 15), app.debugDescription)
            if scenario == "search" {
                XCTAssertTrue(app.staticTexts["photo upload composer readiness"].exists, app.debugDescription)
                XCTAssertTrue(app.staticTexts["Photo attachments and Send readiness"].exists)
                XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "The attachment coordinator owns preparation.")).firstMatch.exists)
            } else {
                let reason = "iOS UI work needing careful ownership and presentation judgment."
                let model = app.descendants(matching: .any)["home-tool-row-Model"]
                let thinking = app.descendants(matching: .any)["home-tool-row-Thinking"]
                XCTAssertTrue(model.label.contains("explicit"))
                XCTAssertFalse(model.label.contains(reason))
                XCTAssertFalse(thinking.label.contains(reason))
                XCTAssertTrue(app.descendants(matching: .any)["home-tool-row-Reason"].label.contains(reason))
                XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Delegated photo-readiness to worker-session")).firstMatch.exists,
                               "Raw admission prose belongs outside the custom Task section")
                app.swipeUp()
                XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Weekly usage 97%")).firstMatch.exists)
                let brief = app.descendants(matching: .any)["home-tool-text-brief"]
                XCTAssertTrue(brief.exists)
                app.swipeDown()
            }
            info.tap()
            let requestJSON = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Inspect Request JSON,")).firstMatch
            XCTAssertTrue(requestJSON.waitForExistence(timeout: 10), app.debugDescription)
            requestJSON.tap()
            XCTAssertTrue(app.staticTexts["Request JSON"].waitForExistence(timeout: 10), app.debugDescription)
            let requested = scenario == "search" ? "photo upload composer readiness" : "photo-readiness"
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", requested)).firstMatch.exists,
                          "Technical inspection must retain the exact request")
            capture(app, "1302-\(scenario)-technical-request")
            app.terminate()
        }
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        // Let the native sheet and media settle, independent of content reads.
        Thread.sleep(forTimeInterval: 0.7)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
