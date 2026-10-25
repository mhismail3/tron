import XCTest

/// Production SwiftUI over synthetic tool invocation/result boundaries.
/// No source assertions or golden snapshots; old renderers fail on visible behavior.
@MainActor final class TronWorkerToolRegressionTests: XCTestCase {
    func testReportShowsMarkdownSummaryEvidenceAndReadableOutcome() {
        continueAfterFailure = false
        for (raw, readable) in [("final", "Done"), ("progress", "Progress"), ("needs-input", "Needs input")] {
            let app = launch("worker-report", extra: ["-worker-report-outcome", raw])
            XCTAssertTrue(app.staticTexts["Report result"].firstMatch.waitForExistence(timeout: 8), app.debugDescription)
            let outcome = app.descendants(matching: .any)["home-tool-outcome"].firstMatch
            XCTAssertTrue(outcome.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertEqual(outcome.label, "Report result, " + readable)
            let summary = app.descendants(matching: .any)["home-tool-text-report"].firstMatch
            let evidence = app.descendants(matching: .any)["home-tool-text-evidence"].firstMatch
            XCTAssertTrue(summary.exists, "Report body must use the custom shared Markdown section")
            XCTAssertTrue(evidence.exists, "Acceptance evidence must not disappear behind the receipt")
            XCTAssertTrue(app.staticTexts["Tool sheets ready"].firstMatch.exists, "Markdown heading must render without ##")
            XCTAssertFalse(app.staticTexts["Task report sealed."].exists, "Receipt text is not the report body")
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '5dee638b'")).firstMatch.exists)
            XCTAssertTrue(app.buttons["Technical details"].exists, "Raw request/result remain reachable")
            attach(app, "report-\(raw)")
            app.terminate()
        }
    }

    func testCheckinKeepsCustomAttentionProgressAndFriendlyTitle() {
        continueAfterFailure = false
        let app = launch("worker-checkin", dark: true)
        XCTAssertTrue(app.staticTexts["Check in"].firstMatch.waitForExistence(timeout: 8), app.debugDescription)
        let outcome = app.descendants(matching: .any)["home-tool-outcome"].firstMatch
        XCTAssertEqual(outcome.label, "Landed with explicit validation deferral, Needs attention")
        for (title, value) in [("Attention", "Requested"), ("Blocker", "Visual approval is needed before testing and landing."),
                               ("Next", "Review the previews, then run focused UI regressions after approval.")] {
            let row = app.descendants(matching: .any)["home-tool-row-\(title)"].firstMatch
            XCTAssertTrue(row.exists, app.debugDescription)
            XCTAssertTrue(row.label.contains(value), "Preserve the canonical \(title) value")
        }
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Checkin Object'")).firstMatch.exists)
        attach(app, "checkin-custom")
        app.terminate()
    }

    func testTranscriptChipsUseFriendlyNames() {
        continueAfterFailure = false
        let app = launch("worker-chips")
        for title in ["Report result", "Check in", "14 tools"] {
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch.waitForExistence(timeout: 8), app.debugDescription)
        }
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'report,' OR label BEGINSWITH 'checkin,'")).firstMatch.exists)
        attach(app, "friendly-chips")
        app.terminate()
    }

    func testAggregateRowsHumanizeExtensionsMCPAndCanonicalToolNames() {
        continueAfterFailure = false
        let app = launch("worker-identities")
        let expected = [("previewDocument", "Preview Document"), ("extension_preview_document", "Extension preview document"),
                        ("mcp__wordcraft__preview_document", "Wordcraft / Preview document"), ("knowledge", "Knowledge"),
                        ("settings", "Settings"), ("subagent", "Subagents"), ("checkin", "Check in"), ("report", "Report result")]
        for (raw, friendly) in expected {
            let row = app.descendants(matching: .any)["tool-run-summary-worker-review-\(raw)"].firstMatch
            for _ in 0..<5 where !row.isHittable { app.scrollViews.firstMatch.swipeUp() }
            XCTAssertTrue(row.exists, app.debugDescription)
            XCTAssertTrue(row.label.hasPrefix(friendly + ","), "Expected \(friendly), got \(row.label)")
        }
        // Open the actual aggregate row: friendly identity must survive navigation.
        app.descendants(matching: .any)["tool-run-summary-worker-review-report"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["home-tool-text-evidence"].firstMatch.waitForExistence(timeout: 8), app.debugDescription)
        attach(app, "aggregate-report-navigation")
        app.terminate()
    }

    private func launch(_ surface: String, dark: Bool = false, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-expanded-review", "-six-ui-surface", surface,
                               "-themeColor", "burgundy", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extra
        if dark { app.launchArguments.append("-settings-renderer-dark") }
        app.launch()
        XCTAssertTrue(app.buttons["Done"].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
