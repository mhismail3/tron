import XCTest

final class TronTaskToolSheetUITests: XCTestCase {
    /// Visual review only: no Gateway mutation or behavioral acceptance suite.
    @MainActor func testCaptureTaskSheetReview() {
        continueAfterFailure = false
        for mode in ["light", "dark"] {
            for scenario in ["task-list", "task-status", "task-report", "task-steer", "task-fallback"] {
                let app = launch(scenario, mode: mode)
                capture(app, "\(scenario)-\(mode)")
                app.swipeUp()
                capture(app, "\(scenario)-\(mode)-lower")
                app.terminate()
            }
        }
        let app = launch("task-list", large: true)
        capture(app, "task-list-large-text")
        app.swipeUp()
        capture(app, "task-list-large-text-lower")
        app.terminate()
    }

    @MainActor func testCatalogShowsTaskContentAndKeepsJSONInTechnicalDetails() {
        continueAfterFailure = false
        let app = launch("task-list")
        defer { app.terminate() }
        let task = app.descendants(matching: .any)["task-tool-row-photo-readiness"]
        XCTAssertTrue(task.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(task.label.contains("Keep Send disabled while photos prepare"))
        XCTAssertTrue(task.label.contains("Running"))
        XCTAssertTrue(task.label.contains("Attachment readiness now has one owner."))
        XCTAssertTrue(app.staticTexts["10 running · 495 finished"].exists)
        let stopped = app.descendants(matching: .any)["task-tool-row-older-layout-audit"]
        for _ in 0..<6 where !stopped.isHittable { app.swipeUp() }
        XCTAssertTrue(stopped.label.contains("older-layout-audit"))
        XCTAssertTrue(stopped.label.contains("Stopped"))
        XCTAssertTrue(app.descendants(matching: .any)["task-tool-row-tool-sheet-review"].label.contains("Needs attention"))
        XCTAssertTrue(app.staticTexts["More tasks are available."].exists)
        app.buttons["Technical details"].tap()
        let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Inspect Result JSON,")).firstMatch
        for _ in 0..<6 where !result.isHittable { app.swipeUp() }
        XCTAssertTrue(result.isHittable, app.debugDescription)
        result.tap()
        XCTAssertTrue(app.staticTexts["Result JSON"].waitForExistence(timeout: 5))
        let raw = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "photo-readiness")).firstMatch
        XCTAssertTrue(raw.waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor func testStatusShowsRecordedWorkerCheckinAndSpend() {
        continueAfterFailure = false
        let app = launch("task-status")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Keep Send disabled while photos prepare"].exists)
        let worker = app.descendants(matching: .any)["home-tool-row-Model"]
        for _ in 0..<6 where !worker.isHittable { app.swipeUp() }
        XCTAssertTrue(worker.label.contains("Sol"), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["home-tool-row-Check-in"].label.contains("Attachment readiness now has one owner."))
        let spend = app.descendants(matching: .any)["home-tool-row-Tokens"]
        for _ in 0..<6 where !spend.isHittable { app.swipeUp() }
        XCTAssertTrue(spend.label.contains("18K in"), app.debugDescription)
    }

    @MainActor func testReportAndControlMessagesOpenOriginalTextInSharedReader() {
        continueAfterFailure = false
        for scenario in ["task-report", "task-steer", "task-resume", "task-interrupt"] {
            let app = launch(scenario)
            let outcome = app.descendants(matching: .any).matching(identifier: "home-tool-outcome").firstMatch
            XCTAssertTrue(outcome.exists, app.debugDescription)
            if scenario == "task-report" {
                XCTAssertTrue(app.descendants(matching: .any)["home-tool-row-Page"].label.contains("Bytes 0–"))
            } else {
                XCTAssertTrue(outcome.label.contains("Accepted"), app.debugDescription)
            }
            if scenario == "task-resume" {
                XCTAssertTrue(app.descendants(matching: .any)["home-tool-row-Continues as task"].label.contains("photo-readiness-2"))
            }
            let id = scenario == "task-report" ? "report" : "message"
            let read = app.buttons["home-tool-text-\(id)-view-all"]
            for _ in 0..<8 where !read.isHittable { app.swipeUp() }
            XCTAssertTrue(read.isHittable, app.debugDescription)
            read.tap()
            XCTAssertTrue(app.descendants(matching: .any)["home-reading-text"].waitForExistence(timeout: 5))
            let tail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Wait for visual approval before behavioral regression runs or merging.")).firstMatch
            for _ in 0..<8 where !tail.isHittable { app.swipeUp() }
            XCTAssertTrue(tail.isHittable, "Full reader retains the original tail")
            app.terminate()
        }
    }

    @MainActor func testRenameStopFallbackAndErrorUseTheirRecordedOutcomes() {
        continueAfterFailure = false
        for scenario in ["task-rename", "task-stop", "task-fallback", "task-malformed", "task-refused"] {
            let app = launch(scenario)
            let custom = app.descendants(matching: .any)["home-tool-detail"]
            if ["task-fallback", "task-malformed"].contains(scenario) {
                XCTAssertFalse(custom.exists, "Unknown or malformed results must retain the generic detail")
            } else {
                XCTAssertTrue(custom.exists, app.debugDescription)
                if scenario == "task-rename" {
                    XCTAssertTrue(app.descendants(matching: .any)["home-tool-row-New title"].label.contains("Photo preparation: ready for review"))
                } else if scenario == "task-stop" {
                    XCTAssertTrue(app.staticTexts["Stop recorded for this exact operation."].exists)
                    XCTAssertFalse(app.descendants(matching: .any)["home-tool-text-message"].exists)
                } else {
                    let failure = app.descendants(matching: .any)["home-tool-failure"]
                    XCTAssertTrue(failure.exists, app.debugDescription)
                    XCTAssertTrue(failure.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Use resume to continue it in place.")).firstMatch.exists)
                }
            }
            app.terminate()
        }
    }

    @MainActor private func launch(_ scenario: String, mode: String = "light", large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-tool-sheets-polish-fixture", "-polish-scenario", scenario,
                               "-polish-\(mode)", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.buttons["Technical details"].waitForExistence(timeout: 15), app.debugDescription)
        return app
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
