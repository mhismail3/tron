import XCTest

/// A finalized parallel group of display calls renders each display as the
/// lone inline display's thumbnail card (`DisplayThumbnailButton`, identifier
/// `display-inline-thumbnail`) in one horizontal row, never as a tool chip, and
/// a thumbnail opens its preview directly instead of going through the grouped
/// tool sheet. Generic calls in a mixed group keep their grouped chip.
final class TronChatDisplayStripUITests: XCTestCase {
    @MainActor func testGroupedDisplaysRenderAsInlineThumbnailRowThatOpensPreviewDirectly() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-chat-display-fixture", "-chat-display-grouped", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); defer { app.terminate() }

        let titles = ["Failure after swap", "Progress sheet: live, then succeeded", "Replace Mac App row (running)", "Settings after replace"]
        let first = thumbnail(app, titles[0])
        XCTAssertTrue(first.waitForExistence(timeout: 20), app.debugDescription)
        let grouped = app.buttons.matching(NSPredicate(format: "label CONTAINS ' tools'")).firstMatch
        XCTAssertFalse(grouped.exists, "Display calls must not collapse into a grouped tools chip: \(grouped.exists ? grouped.label : "")\n\(app.debugDescription)")
        let second = thumbnail(app, titles[1])
        XCTAssertTrue(second.exists)
        // Each display is the shared inline thumbnail card, not its tool chip.
        for title in titles {
            XCTAssertFalse(app.buttons["\(title), Open, Opens sheet"].exists, "\(title) must not render as a tool chip")
        }
        XCTAssertFalse(app.buttons["Release notes, Open, Opens sheet"].exists, "A non-image display must not render as a tool chip")
        for thumbnail in [first, second] {
            XCTAssertEqual(thumbnail.identifier, "display-inline-thumbnail")
            XCTAssertEqual(thumbnail.frame.width, Self.thumbnailSide, accuracy: 1, "The inline thumbnail's own size")
            XCTAssertEqual(thumbnail.frame.height, Self.thumbnailSide, accuracy: 1)
        }
        XCTAssertEqual(first.frame.midY, second.frame.midY, accuracy: 1, "Grouped displays share one row")
        XCTAssertGreaterThan(second.frame.minX, first.frame.maxX, "Chips run left to right in invocation order")
        keepScreenshot(app, "998-display-thumbnail-row")

        // The row scrolls horizontally to reach later thumbnails.
        let last = thumbnail(app, titles[3])
        XCTAssertTrue(last.exists)
        // Drag on the thumbnails themselves: the row, not the transcript, scrolls.
        let rowY = first.frame.midY
        for _ in 0..<3 where !last.isHittable {
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 360, dy: rowY))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -320, dy: 0)))
        }
        XCTAssertTrue(waitHittable(last), "The last thumbnail scrolls into reach")
        XCTAssertEqual(last.frame.midY, first.frame.midY, accuracy: 1)
        // A non-image display keeps the same card with its kind's face.
        let document = app.buttons["Open Release notes"]
        XCTAssertTrue(document.exists, app.debugDescription)
        XCTAssertEqual(document.identifier, "display-inline-thumbnail")
        XCTAssertEqual(document.frame.midY, first.frame.midY, accuracy: 1)
        XCTAssertEqual(document.frame.width, Self.thumbnailSide, accuracy: 1)
        keepScreenshot(app, "998-display-thumbnail-row-scrolled")

        // One tap opens that display's preview sheet; no grouped tool sheet.
        last.tap()
        XCTAssertTrue(app.images["Settings row"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'tool-run-summary-'")).firstMatch.exists,
                       "The grouped tool sheet listing every display must not open")
        keepScreenshot(app, "998-display-preview-direct")
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(app.images["Settings row"].waitForNonExistence(timeout: 10))

        // Mixed group: the display run is split out; generic calls keep chips.
        let mixedOne = thumbnail(app, "Mixed photo one")
        let mixedTwo = thumbnail(app, "Mixed photo two")
        XCTAssertTrue(mixedOne.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(mixedOne.frame.midY, mixedTwo.frame.midY, accuracy: 1)
        XCTAssertEqual(mixedOne.identifier, "display-inline-thumbnail")
        // Each generic stretch counts only its own call, not the group's four.
        let read = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Read file, Completed'")).firstMatch
        let bash = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Run command, Completed'")).firstMatch
        XCTAssertTrue(read.exists, app.debugDescription)
        XCTAssertTrue(bash.exists, app.debugDescription)
        XCTAssertLessThan(read.frame.maxY, mixedOne.frame.minY, "The read call keeps its chip above the display row")
        XCTAssertLessThan(read.frame.height, mixedOne.frame.height, "Generic calls stay compact chips")
        XCTAssertGreaterThan(bash.frame.minY, mixedOne.frame.maxY, "The shell call keeps its chip below")
        keepScreenshot(app, "998-display-thumbnail-row-mixed")
        mixedTwo.tap()
        XCTAssertTrue(app.images["Mixed two"].waitForExistence(timeout: 10), app.debugDescription)
    }

    /// `DisplayInlineLayoutPolicy.imageChipSide`: the attachment preview side × 1.7.
    static let thumbnailSide: CGFloat = 64 * 1.7

    @MainActor private func thumbnail(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons["Open \(title) photo preview"]
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
