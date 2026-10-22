import XCTest

/// Measures the shared feed (#1691) on 6,733 Session History entries. A
/// measurement, not a validation gate; run it explicitly.
final class TronListStandardPerformanceUITests: XCTestCase {
    /// Session History over 6,733 entries: time to the first rows, time and swipes
    /// to auto-load 1,000 entries, then scroll hitches and memory with them loaded.
    @MainActor func testLargeHistoryScrollPerformance() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-configuration-fixture", "-history-large", "-fixture-appearance", "light"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 10))
        app.buttons["Stop session"].tap()
        let history = app.buttons["Session History"]
        for _ in 0..<12 where !history.isHittable { app.swipeUp() }
        let opened = Date()
        history.tap()
        XCTAssertTrue(app.buttons["history-row-h-6732"].waitForExistence(timeout: 10), app.debugDescription)
        let firstRows = Date().timeIntervalSince(opened)
        expandSheet(app, title: "Session History")
        let target = app.buttons["history-row-h-5733"]
        let started = Date()
        var swipes = 0
        while !target.exists && swipes < 400 { app.swipeUp(velocity: .fast); swipes += 1 }
        let loaded = Date().timeIntervalSince(started)
        XCTAssertTrue(target.exists, "1,000 entries auto-load by scrolling alone")
        let report = String(format: "list-standard-perf firstRows=%.2fs load1000=%.1fs swipes=%d perSwipe=%.2fs", firstRows, loaded, swipes, loaded / Double(max(swipes, 1)))
        print(report)
        let attachment = XCTAttachment(string: report)
        attachment.name = "large-history-perf"
        attachment.lifetime = .keepAlways
        add(attachment)
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric, XCTMemoryMetric(application: app)], options: options) {
            app.swipeUp(velocity: .fast)
            app.swipeDown(velocity: .fast)
        }
    }

    @MainActor private func expandSheet(_ app: XCUIApplication, title text: String) {
        let title = app.navigationBars.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 8), app.debugDescription)
        Thread.sleep(forTimeInterval: 1)
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        for _ in 0..<4 where title.frame.minY > 120 {
            origin.withOffset(CGVector(dx: 60, dy: title.frame.midY))
                .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: 60, dy: 20)))
            Thread.sleep(forTimeInterval: 0.6)
        }
    }
}
