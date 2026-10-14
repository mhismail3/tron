import XCTest

/// The session row's relative-time label (#975): never future-tense, and the
/// same laid-out width while it ticks, so the row title keeps one truncation
/// point. Drives the real `HistoricalSessionRow` and `SessionRowRelativeTime`.
final class TronSessionRowClockUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testRelativeTimeReadsNowAndKeepsOneWidthAsItTicks() {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-row-clock-fixture"]
        app.launch()

        // Rows at a gateway clock 3s ahead, just now, 12s and 47m ago.
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Refactor the gateway reconnect handshake so phones resume cleanly, "))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "975-session-row-clock"
        shot.lifetime = .keepAlways
        add(shot)
        let rowTimes = rows.allElementsBoundByIndex.map { $0.label.components(separatedBy: ", ").last ?? "" }
        XCTAssertEqual(rowTimes, ["now", "now", "12s ago", "47m ago"])

        // Step the real label through future, zero and past values.
        let label = app.descendants(matching: .any)["row-clock-label"]
        XCTAssertTrue(label.waitForExistence(timeout: 5))
        let width = app.staticTexts["row-clock-label-width"]
        let laidOut = width.label
        XCTAssertGreaterThan(Double(laidOut) ?? 0, 0)
        var labels = [label.label]
        for _ in 1..<8 {
            app.buttons["row-clock-next"].tap()
            labels.append(label.label)
            XCTAssertEqual(width.label, laidOut, "laid-out width changed at \(label.label)")
        }
        XCTAssertEqual(labels, ["now", "now", "now", "5s ago", "59s ago", "1m ago", "12m ago", "3h ago"])
    }
}
