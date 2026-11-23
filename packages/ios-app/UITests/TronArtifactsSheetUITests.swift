import XCTest

final class TronArtifactsSheetUITests: XCTestCase {
    @MainActor
    func testArtifactsListNewestFirstAndOpenTheirTailnetPage() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-integrations-fixture", "-integrations-scenario", "artifacts",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            + ProcessInfo.processInfo.environment.compactMap { $0.key == "TRON_ARTIFACTS_BASE_URL" ? ["-artifacts-base-url", $0.value] : nil }.flatMap { $0 }
        app.launch()
        defer { app.terminate() }
        let open = app.buttons["Artifacts"]
        XCTAssertTrue(open.waitForExistence(timeout: 20), app.debugDescription)
        open.tap()
        let rows = ["2026-11-23_weekly-status", "2026-11-21_release-guide", "2026-11-18_gapyear-schedule"].map { app.buttons["artifact-row-\($0)"] }
        XCTAssertTrue(rows[0].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(rows.map(\.exists), [true, true, true])
        XCTAssertLessThan(rows[0].frame.minY, rows[1].frame.minY)
        XCTAssertLessThan(rows[1].frame.minY, rows[2].frame.minY)
        XCTAssertTrue(rows[0].label.contains("weekly status") && rows[0].label.contains("2026-11-23"), rows[0].label)
        keepScreenshot(app, "artifacts-sheet-list")
        rows[0].tap()
        let host = ProcessInfo.processInfo.environment["TRON_ARTIFACTS_BASE_URL"].flatMap { URL(string: $0)?.host } ?? "mac.example.ts.net"
        XCTAssertTrue(app.descendants(matching: .any).containing(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", host, host))
            .firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        Thread.sleep(forTimeInterval: 2)
        keepScreenshot(app, "artifacts-open-artifact")
    }

    @MainActor private func keepScreenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
