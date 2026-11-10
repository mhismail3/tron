import XCTest

final class TronAutomationsListPerformanceUITests: XCTestCase {
    @MainActor func testLargeInventoryScrollPerformance() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-automation-fixture", "-automation-large", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); defer { app.terminate() }
        let menu = app.buttons["dashboard.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), app.debugDescription)
        menu.tap()
        let opened = Date()
        app.buttons["Automations"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'automation-card.'")).firstMatch
            .waitForExistence(timeout: 15), app.debugDescription)
        let firstRows = Date().timeIntervalSince(opened)
        expandSheet(app, title: "Automations")
        let started = Date()
        let swipes = 40
        for _ in 0..<swipes { app.swipeUp(velocity: .fast) }
        let scrolled = Date().timeIntervalSince(started)
        let report = String(format: "automations-list-perf firstRows=%.2fs scroll=%.1fs swipes=%d perSwipe=%.3fs",
                            firstRows, scrolled, swipes, scrolled / Double(swipes))
        print(report)
        let attachment = XCTAttachment(string: report)
        attachment.name = "automations-list-perf"
        attachment.lifetime = .keepAlways
        add(attachment)
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTCPUMetric(application: app), XCTOSSignpostMetric.scrollDecelerationMetric,
                          XCTMemoryMetric(application: app)], options: options) {
            for _ in 0..<3 { app.swipeDown(velocity: .fast) }
            for _ in 0..<3 { app.swipeUp(velocity: .fast) }
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
