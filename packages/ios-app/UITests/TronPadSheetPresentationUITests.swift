import XCTest

/// The iPad sheet geometry owned by `TronPadSheetMode` (iPadOS 27): a scene at
/// least 1100 pt wide shows managed sheets as a trailing side column that leaves
/// the chat interactive, and a narrower scene shows one large centered sheet. iPhone keeps native detent sheets
/// (`TronSmokeUITests.testManageHomeOpensAtMediumFromRingAndHomeGearOpensSettings`).
/// Run on an iPad lane: `scripts/tron-ios-test run --lane ipad --device-type "iPad Pro 13-inch (M5)"`.
final class TronPadSheetPresentationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad sheet geometry needs an iPad simulator lane")
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    /// Full-screen landscape: Manage Home and Global Settings open as a trailing
    /// column, and the chat beside them still takes taps and text.
    @MainActor
    func testWideLandscapePrimarySheetsAreTrailingColumnsBesideAnInteractiveChat() {
        let app = launchHomeChat(orientation: .landscapeLeft)
        defer { app.terminate() }
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(window.width, 1100, "A full-screen landscape iPad Pro 13\" window is wide")

        openManageHome(app)
        let manage = sheetFrame(app, title: "Manage Home", done: app.buttons["home-sheet-done-manage"])
        assertTrailingColumn(manage, in: window)
        keepScreenshot(app, "ipad-landscape-manage-home")
        assertChatInteractive(app, beside: manage, typing: "Typed beside Manage Home")
        XCTAssertTrue(app.descendants(matching: .any)["home-manage-state"].exists, "Using the chat must not dismiss Manage Home")
        app.buttons["home-sheet-done-manage"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["home-manage-state"].waitForNonExistence(timeout: 5))

        let gear = app.navigationBars.buttons["Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 5), app.debugDescription)
        gear.tap()
        let title = app.staticTexts["Global Settings"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), app.debugDescription)
        let settings = sheetFrame(app, title: "Global Settings", done: app.buttons["Done"].firstMatch)
        assertTrailingColumn(settings, in: window)
        keepScreenshot(app, "ipad-landscape-global-settings")
        assertChatInteractive(app, beside: settings, typing: " and beside Global Settings")
    }

    /// A sheet opened from the side column stacks on it in that column, the
    /// parent's top edge showing, and still leaves the chat interactive.
    @MainActor
    func testWideLandscapeSubSheetStacksInsideTheSideColumn() {
        let app = launchHomeChat(orientation: .landscapeLeft)
        defer { app.terminate() }
        let window = app.windows.firstMatch.frame
        openManageHome(app)
        let parent = sheetFrame(app, title: "Manage Home", done: app.buttons["home-sheet-done-manage"])
        assertTrailingColumn(parent, in: window)

        let row = app.descendants(matching: .any)["home-manage-settings"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["home-settings-controls"].waitForExistence(timeout: 8), app.debugDescription)
        let childTitle = app.staticTexts["Home Settings"].firstMatch
        XCTAssertTrue(childTitle.waitForExistence(timeout: 5), app.debugDescription)
        let childDone = app.buttons.matching(NSPredicate(format: "label == 'Done'")).allElementsBoundByIndex
            .max { $0.frame.minY < $1.frame.minY } ?? app.buttons["Done"]
        let child = sheetFrame(app, title: "Home Settings", done: childDone)
        assertTrailingColumn(child, in: window)
        XCTAssertEqual(child.minX, parent.minX, accuracy: 24, "The child sheet stays in the parent's column")
        XCTAssertGreaterThan(child.minY, parent.minY, "Manage Home's top edge shows above the stacked Home Settings: \(child) over \(parent)")
        keepScreenshot(app, "ipad-landscape-manage-home-home-settings-stacked")
        assertChatInteractive(app, beside: child, typing: "Typed beside Home Settings")
        XCTAssertTrue(app.descendants(matching: .any)["home-settings-controls"].exists, "Using the chat must not dismiss Home Settings")
    }

    /// Portrait full screen is narrower than the side-column threshold: one
    /// large centered sheet that a title drag does not resize.
    @MainActor
    func testNarrowWindowShowsOneFixedCenteredSheetWithoutDetents() {
        let app = launchHomeChat(orientation: .portrait)
        defer { app.terminate() }
        let window = app.windows.firstMatch.frame
        XCTAssertLessThan(window.width, 1100, "Portrait full screen is below the side-column threshold")
        openManageHome(app)
        let done = app.buttons["home-sheet-done-manage"]
        let card = sheetFrame(app, title: "Manage Home", done: done)
        XCTAssertEqual(card.midX, window.midX, accuracy: 2, "The narrow sheet is horizontally centered")
        XCTAssertGreaterThan(card.minX, window.minX + 16, "The narrow sheet is a card, not full width")
        XCTAssertGreaterThan(card.minY, window.minY + 20, "The narrow sheet is a card, not edge-attached to the top")
        XCTAssertLessThan(done.frame.minY, window.minY + window.height * 0.3, "The narrow sheet opens at its one large size, not a medium detent")
        keepScreenshot(app, "ipad-portrait-manage-home")
        let title = app.staticTexts["Manage Home"].firstMatch
        let before = done.frame
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)))
        Thread.sleep(forTimeInterval: 1) // a detent change would have settled
        XCTAssertEqual(done.frame, before, "The narrow sheet has one size: a drag changes no detent")
        XCTAssertTrue(app.descendants(matching: .any)["home-manage-state"].exists)
    }

    // MARK: - Helpers

    @MainActor
    private func launchHomeChat(orientation: UIDeviceOrientation) -> XCUIApplication {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
        app.launch()
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["home-pinned-row"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Home"].waitForExistence(timeout: 10), app.debugDescription)
        return app
    }

    @MainActor
    private func openManageHome(_ app: XCUIApplication) {
        let ring = app.buttons["session-context-button"]
        XCTAssertTrue(ring.waitForExistence(timeout: 10), app.debugDescription)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND label CONTAINS 'Manage Home'"), object: ring)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed, app.debugDescription)
        ring.tap()
        XCTAssertTrue(app.descendants(matching: .any)["home-manage-state"].waitForExistence(timeout: 5), app.debugDescription)
        Thread.sleep(forTimeInterval: 1) // let the presentation transition settle before reading frames
    }

    /// The sheet's chrome bounds as read from its own title and Done button: its
    /// leading edge is its title's mirrored Done inset, its top the Done button.
    @MainActor
    private func sheetFrame(_ app: XCUIApplication, title: String, done: XCUIElement) -> CGRect {
        let titleElement = app.staticTexts[title].firstMatch
        XCTAssertTrue(titleElement.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(done.waitForExistence(timeout: 5), app.debugDescription)
        let doneFrame = done.frame
        let center = titleElement.frame.midX
        let halfWidth = doneFrame.maxX + 16 - center
        return CGRect(x: center - halfWidth, y: doneFrame.minY - 12, width: halfWidth * 2, height: app.windows.firstMatch.frame.maxY - doneFrame.minY)
    }

    /// A tall trailing column: at the trailing edge, right of center, and opened
    /// at full height (its top within the window's top fifth, not a medium detent).
    private func assertTrailingColumn(_ sheet: CGRect, in window: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(sheet.minX, window.midX, "The sheet occupies a trailing column, not the middle: \(sheet) in \(window)", file: file, line: line)
        XCTAssertGreaterThan(sheet.maxX, window.maxX - 48, "The sheet sits at the trailing edge: \(sheet) in \(window)", file: file, line: line)
        XCTAssertLessThan(sheet.minY, window.minY + window.height * 0.2, "The column is full height, not a medium detent: \(sheet) in \(window)", file: file, line: line)
    }

    /// The chat beside the sheet is not covered and still takes a tap and text.
    /// (The sheet keeps an accessibility-only dismiss region over the window, so
    /// `isHittable` is not the oracle; the typed text reaching the composer is.)
    @MainActor
    private func assertChatInteractive(_ app: XCUIApplication, beside sheet: CGRect, typing text: String, file: StaticString = #filePath, line: UInt = #line) {
        let composer = app.textViews["Message input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5), app.debugDescription, file: file, line: line)
        XCTAssertLessThanOrEqual(composer.frame.maxX, sheet.minX, "The chat lays out beside the sheet, not under it", file: file, line: line)
        composer.tap()
        composer.typeText(text)
        let typed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", text), object: composer)
        XCTAssertEqual(XCTWaiter.wait(for: [typed], timeout: 5), .completed, "The chat composer takes text beside the sheet", file: file, line: line)
    }

    @MainActor
    private func keepScreenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
