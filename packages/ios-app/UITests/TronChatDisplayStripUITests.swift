import XCTest

/// A finalized parallel group of display calls renders each display's own chip
/// in one horizontal row, and a chip opens its preview directly instead of
/// going through the grouped tool sheet. Generic calls in a mixed group keep
/// their grouped chip.
final class TronChatDisplayStripUITests: XCTestCase {
    @MainActor func testGroupedDisplaysRenderAsChipRowThatOpensPreviewDirectly() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-chat-display-fixture", "-chat-display-grouped", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); defer { app.terminate() }

        let titles = ["Failure after swap", "Progress sheet: live, then succeeded", "Replace Mac App row (running)", "Settings after replace"]
        let first = chip(app, titles[0])
        XCTAssertTrue(first.waitForExistence(timeout: 20), app.debugDescription)
        let grouped = app.buttons.matching(NSPredicate(format: "label CONTAINS ' tools'")).firstMatch
        XCTAssertFalse(grouped.exists, "Display calls must not collapse into a grouped tools chip: \(grouped.exists ? grouped.label : "")\n\(app.debugDescription)")
        let second = chip(app, titles[1])
        XCTAssertTrue(second.exists)
        XCTAssertEqual(first.frame.midY, second.frame.midY, accuracy: 1, "Grouped displays share one row")
        XCTAssertGreaterThan(second.frame.minX, first.frame.maxX, "Chips run left to right in invocation order")
        keepScreenshot(app, "989-display-chip-row")

        // The row scrolls horizontally to reach later chips.
        let last = chip(app, titles[3])
        XCTAssertTrue(last.exists)
        // Drag on the chips themselves: the row, not the transcript, scrolls.
        let rowY = first.frame.midY
        for _ in 0..<3 where !last.isHittable {
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 360, dy: rowY))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -320, dy: 0)))
        }
        XCTAssertTrue(waitHittable(last), "The last chip scrolls into reach")
        XCTAssertEqual(last.frame.midY, first.frame.midY, accuracy: 1)
        keepScreenshot(app, "989-display-chip-row-scrolled")

        // One tap opens that display's preview sheet; no grouped tool sheet.
        last.tap()
        XCTAssertTrue(app.images["Settings row"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'tool-run-summary-'")).firstMatch.exists,
                       "The grouped tool sheet listing every display must not open")
        keepScreenshot(app, "989-display-preview-direct")
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(app.images["Settings row"].waitForNonExistence(timeout: 10))

        // Mixed group: the display run is split out; generic calls keep chips.
        let mixedOne = chip(app, "Mixed photo one")
        let mixedTwo = chip(app, "Mixed photo two")
        XCTAssertTrue(mixedOne.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(mixedOne.frame.midY, mixedTwo.frame.midY, accuracy: 1)
        // Each generic stretch counts only its own call, not the group's four.
        let read = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Read file, Completed'")).firstMatch
        let bash = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Run command, Completed'")).firstMatch
        XCTAssertTrue(read.exists, app.debugDescription)
        XCTAssertTrue(bash.exists, app.debugDescription)
        XCTAssertLessThan(read.frame.maxY, mixedOne.frame.minY, "The read call keeps its chip above the display row")
        XCTAssertGreaterThan(bash.frame.minY, mixedOne.frame.maxY, "The shell call keeps its chip below")
        keepScreenshot(app, "989-display-chip-row-mixed")
        mixedTwo.tap()
        XCTAssertTrue(app.images["Mixed two"].waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor private func chip(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(title), Open")).firstMatch
    }

    @MainActor private func waitHittable(_ element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }

    @MainActor private func keepScreenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
