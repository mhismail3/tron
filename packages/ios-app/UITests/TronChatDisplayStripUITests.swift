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

        // The row scrolls horizontally: the trailing non-image display starts
        // off screen and is reached by dragging the row itself.
        let last = thumbnail(app, titles[3])
        XCTAssertTrue(last.exists)
        let document = app.buttons["Open Release notes"]
        XCTAssertTrue(document.exists, app.debugDescription)
        XCTAssertFalse(document.isHittable, "The fifth thumbnail starts beyond the screen edge")
        let rowY = first.frame.midY
        for _ in 0..<3 where !document.isHittable {
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 360, dy: rowY))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -320, dy: 0)))
        }
        XCTAssertTrue(waitHittable(document), "The last thumbnail scrolls into reach")
        XCTAssertLessThan(first.frame.minX, 0, "The row, not the transcript, scrolled")
        XCTAssertEqual(document.frame.midY, first.frame.midY, accuracy: 1)
        // A non-image display keeps the same card with its kind's face.
        XCTAssertEqual(document.identifier, "display-inline-thumbnail")
        XCTAssertEqual(document.frame.width, Self.thumbnailSide, accuracy: 1)
        XCTAssertEqual(document.frame.height, Self.thumbnailSide, accuracy: 1)
        XCTAssertTrue(waitHittable(last))
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

    /// A chat reopened from history with a grouped run of inline image displays
    /// lays its cards out exactly as the live chat that produced them: each
    /// card's slot is the card itself, so the row's spacing (`ChatChipStrip`,
    /// 8 pt) separates every pair. Collapsing one card with its x and expanding
    /// its chip again keeps that spacing (#1012).
    @MainActor func testReopenedInlineDisplayGroupKeepsLiveCardSpacingThroughCollapseAndExpand() {
        continueAfterFailure = false
        let reopened = launch("-chat-display-inline-group")
        let reopenedFrames = inlineCardFrames(reopened, name: "1012-reopened-inline-group")
        reopened.terminate()

        let live = launch("-chat-display-inline-group-live")
        let liveFrames = inlineCardFrames(live, name: "1012-live-inline-group")
        live.terminate()
        for (reopenedFrame, liveFrame) in zip(reopenedFrames, liveFrames) {
            XCTAssertEqual(reopenedFrame.minX, liveFrame.minX, accuracy: 1, "Reopened cards sit where live cards do")
            XCTAssertEqual(reopenedFrame.width, liveFrame.width, accuracy: 1)
        }

        let app = launch("-chat-display-inline-group")
        defer { app.terminate() }
        let original = inlineCardFrames(app, name: "1012-reopened-before-collapse")
        let titles = Self.inlineTitles
        let collapse = app.buttons["Collapse \(titles[1])"]
        XCTAssertTrue(collapse.waitForExistence(timeout: 10), app.debugDescription)
        collapse.tap()
        let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(titles[1]), Show inline")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(thumbnail(app, titles[1]).waitForNonExistence(timeout: 10), "The x collapses that card into its chip")
        let first = thumbnail(app, titles[0]), third = thumbnail(app, titles[2])
        XCTAssertTrue(waitFrameStable(third))
        keepScreenshot(app, "1012-reopened-collapsed")
        XCTAssertEqual(first.frame.minX, original[0].minX, accuracy: 1, "Cards before the chip do not move")
        XCTAssertEqual(chip.frame.minX - first.frame.maxX, Self.rowSpacing, accuracy: 1, "Card to chip keeps the row spacing")
        XCTAssertEqual(third.frame.minX - chip.frame.maxX, Self.rowSpacing, accuracy: 1, "Chip to card keeps the row spacing")
        XCTAssertLessThan(chip.frame.height, Self.thumbnailSide, "The collapsed display is the compact chip")

        chip.tap()
        let restored = thumbnail(app, titles[1])
        XCTAssertTrue(restored.waitForExistence(timeout: 10), "Tapping the chip expands the card again")
        XCTAssertTrue(waitFrameStable(third))
        keepScreenshot(app, "1012-reopened-expanded-again")
        for (index, title) in titles.enumerated() where index < 3 {
            let frame = thumbnail(app, title).frame
            XCTAssertEqual(frame.minX, original[index].minX, accuracy: 1, "\(title) returns to its original slot")
            XCTAssertEqual(frame.width, Self.thumbnailSide, accuracy: 1)
        }
    }

    /// The grouped inline cards' frames, asserting the row is tight and even.
    @MainActor private func inlineCardFrames(_ app: XCUIApplication, name: String) -> [CGRect] {
        let titles = Self.inlineTitles
        let first = thumbnail(app, titles[0])
        XCTAssertTrue(first.waitForExistence(timeout: 20), app.debugDescription)
        let third = thumbnail(app, titles[2])
        XCTAssertTrue(third.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(waitFrameStable(third))
        keepScreenshot(app, name)
        let frames = titles.prefix(3).map { thumbnail(app, $0).frame }
        for frame in frames {
            XCTAssertEqual(frame.width, Self.thumbnailSide, accuracy: 1, "The card's own size")
            XCTAssertEqual(frame.midY, frames[0].midY, accuracy: 1, "One row")
        }
        for (left, right) in zip(frames, frames.dropFirst()) {
            XCTAssertEqual(right.minX - left.maxX, Self.rowSpacing, accuracy: 1,
                           "\(name): each card's slot is its card, so only the row spacing separates them")
        }
        return frames
    }

    @MainActor private func launch(_ mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-chat-display-fixture", mode, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    @MainActor private func waitFrameStable(_ element: XCUIElement) -> Bool {
        var last = element.frame
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.25)
            let next = element.frame
            if next == last, element.exists { return true }
            last = next
        }
        return false
    }

    static let inlineTitles = ["Home dashboard after the fix", "Usage sheet with rounded rows",
                               "Settings: This iPhone switch", "Worker list scrolled to the end"]
    /// `ChatChipStrip`'s spacing between row items.
    static let rowSpacing: CGFloat = 8

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
