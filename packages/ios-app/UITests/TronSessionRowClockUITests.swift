import XCTest

final class TronSessionRowClockUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testDashboardMetadataUsesSharedCodeTypography() {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-row-clock-fixture", "-dashboard-row-typography",
                               "-fontFamily", "sourceSerif4", "-monoFontFamily", "jetBrainsMono"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["subtitle-reference-iiiiiiii"].waitForExistence(timeout: 10))
        for sample in ["iiiiiiii", "WWWWWWWW"] {
            let subtitle = app.staticTexts.matching(NSPredicate(format: "label == %@ AND NOT identifier BEGINSWITH 'subtitle-reference-'", sample)).firstMatch
            let timestamp = app.descendants(matching: .any)["timestamp-\(sample)"].firstMatch
            for (actual, reference) in [(subtitle, app.staticTexts["subtitle-reference-\(sample)"]),
                                        (timestamp, app.staticTexts["timestamp-reference-\(sample)"])] {
                XCTAssertTrue(actual.exists, app.debugDescription)
                XCTAssertEqual(actual.frame.width, reference.frame.width, accuracy: 0.5,
                               "\(sample): metadata must use shared code glyph advances")
                XCTAssertEqual(actual.frame.height, reference.frame.height, accuracy: 0.5,
                               "\(sample): metadata must keep shared code caption metrics")
            }
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "1762-shared-row-code-typography"
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testRelativeTimeReadsNowAndKeepsOneWidthAsItTicks() {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-row-clock-fixture"]
        app.launch()

        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Refactor the gateway reconnect handshake so phones resume cleanly, "))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "975-session-row-clock"
        shot.lifetime = .keepAlways
        add(shot)
        let rowTimes = rows.allElementsBoundByIndex.map { $0.label.components(separatedBy: ", ").last ?? "" }
        XCTAssertEqual(rowTimes, ["now", "now", "12s ago", "47m ago"])

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
