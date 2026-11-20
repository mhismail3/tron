import XCTest

@MainActor final class TronWorkerToolRegressionTests: XCTestCase {
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
        app.descendants(matching: .any)["tool-run-summary-worker-review-report"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["home-tool-text-evidence"].firstMatch.waitForExistence(timeout: 8), app.debugDescription)
        attach(app, "aggregate-report-navigation")
        app.terminate()
    }

    private func launch(_ surface: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-fixture", "-settings-expanded-review", "-six-ui-surface", surface,
                               "-themeColor", "burgundy", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["Done"].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
