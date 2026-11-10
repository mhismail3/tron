import XCTest

private enum TronPadGeometry {
    static let gap: CGFloat = 12
    static let reflowInset: CGFloat = 457
}

final class TronPadSheetPresentationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad sheet geometry needs an iPad simulator lane")
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

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

    @MainActor
    func testWideLandscapeSessionSheetIsATrailingColumn() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-configuration-fixture"]
        app.launch()
        defer { app.terminate() }
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(window.width, 1100, "Full-screen landscape iPad is wide")
        let stop = app.descendants(matching: .any)["Stop session"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 10), app.debugDescription)
        stop.tap()
        let done = app.navigationBars.containing(.staticText, identifier: "Manage Session").buttons["Done"].firstMatch
        let sheet = sheetFrame(app, title: "Manage Session", done: done)
        assertTrailingColumn(sheet, in: window)
        keepScreenshot(app, "ipad-landscape-manage-session")
    }

    @MainActor
    func testWideLandscapeDashboardNewSessionIsAPinnedColumnBesideTheShrunkenList() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
        app.launch()
        defer { app.terminate() }
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(window.width, 1100)
        let menuButton = app.buttons["dashboard.menu"]
        XCTAssertTrue(menuButton.waitForExistence(timeout: 15), app.debugDescription)
        let listBefore = app.collectionViews.firstMatch.frame
        menuButton.press(forDuration: 0.3)
        let item = app.buttons["New Session"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription)
        item.tap()
        let title = app.staticTexts["New Session"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 8), app.debugDescription)
        Thread.sleep(forTimeInterval: 1.5)
        keepScreenshot(app, "ipad-landscape-dashboard-new-session")
        let panel = app.descendants(matching: .any)["tron-scene-panel"].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5), app.debugDescription)
        let sheet = sheetFrame(app, title: "New Session", done: app.buttons["Create"].firstMatch)
        assertTrailingColumn(sheet, in: window)
        let list = app.collectionViews.firstMatch.frame
        XCTAssertLessThan(list.width, listBefore.width - 300, "The dashboard list narrows beside the column: \(list) from \(listBefore)")
        XCTAssertLessThanOrEqual(list.maxX, sheet.minX, "The list does not sit under the sheet: \(list) vs \(sheet)")
        XCTAssertLessThanOrEqual(panel.frame.maxX, sheet.minX, "The panel and column do not overlap")
        let columnMinX = title.frame.midX - 210
        XCTAssertEqual(columnMinX - panel.frame.maxX, TronPadGeometry.gap, accuracy: 3, "A constant gap separates the panels")
        XCTAssertLessThanOrEqual(sheet.maxX, window.maxX + 1, "The column is not clipped by the window")
        let chips = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'new-session-card.'")).allElementsBoundByIndex
        for chip in chips where chip.exists {
            XCTAssertLessThanOrEqual(chip.frame.maxX, sheet.maxX + 1, "\(chip.identifier) is not clipped at the column edge: \(chip.frame) in \(sheet)")
        }
    }

    @MainActor
    func testWideLandscapePanelCarriesItsChromeAndKeepsAConstantGapThroughTheTransition() {
        let app = launchHomeChat(orientation: .landscapeLeft)
        defer { app.terminate() }
        let window = app.windows.firstMatch.frame
        let gear = app.navigationBars.buttons["Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 5), app.debugDescription)
        let panel = app.descendants(matching: .any)["tron-scene-panel"].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertEqual(panel.frame.maxX, window.maxX, accuracy: 1, "The closed scene fills the window")
        let gearClosed = gear.frame

        let ring = app.buttons["session-context-button"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND label CONTAINS 'Manage Home'"), object: ring)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed, app.debugDescription)
        ring.tap()
        var samples: [(gear: CGRect, panel: CGRect)] = []
        for index in 0..<6 {
            samples.append((gear.frame, panel.frame))
            if index == 1 { keepScreenshot(app, "ipad-side-column-mid-transition") }
        }
        XCTAssertTrue(app.descendants(matching: .any)["home-manage-state"].waitForExistence(timeout: 5), app.debugDescription)
        Thread.sleep(forTimeInterval: 1.5)
        keepScreenshot(app, "ipad-side-column-open")
        let open = (gear: gear.frame, panel: panel.frame)
        samples.append(open)
        for sample in samples {
            XCTAssertLessThanOrEqual(sample.gear.maxX, sample.panel.maxX + 1, "The Settings gear stays inside the panel: \(sample)")
        }
        XCTAssertLessThan(open.gear.minX, gearClosed.minX - 300, "The gear moved with the content: \(gearClosed) -> \(open.gear)")
        XCTAssertEqual(open.panel.maxX, window.maxX - TronPadGeometry.reflowInset, accuracy: 2, "The panel ends at the column's gap")
        let title = app.staticTexts["Manage Home"].firstMatch
        XCTAssertEqual((title.frame.midX - 210) - open.panel.maxX, TronPadGeometry.gap, accuracy: 3, "A constant gap separates the panels")

        app.buttons["home-sheet-done-manage"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["home-manage-state"].waitForNonExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(panel.frame.maxX, window.maxX, accuracy: 1, "The content widens back to full width on dismissal")
        XCTAssertEqual(gear.frame.minX, gearClosed.minX, accuracy: 1, "The gear returns with it")
    }

    @MainActor
    func testSheetModeFollowsSimulatedWindowWidthAcrossTheThreshold() {
        for (width, column) in [(1210, true), (1100, true), (1099, false), (900, false), (700, false)] {
            XCUIDevice.shared.orientation = .landscapeLeft
            let app = XCUIApplication()
            app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-tron-scene-width-override", "\(width)"]
            app.launch()
            let window = app.windows.firstMatch.frame
            XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10), app.debugDescription)
            app.buttons["home-pinned-row"].tap()
            openManageHome(app)
            let sheet = sheetFrame(app, title: "Manage Home", done: app.buttons["home-sheet-done-manage"])
            keepScreenshot(app, "simulated-width-\(width)")
            if column {
                assertTrailingColumn(sheet, in: window)
            } else {
                XCTAssertEqual(sheet.midX, window.midX, accuracy: 6, "\(width) pt: a centered card: \(sheet) in \(window)")
            }
            XCTAssertGreaterThanOrEqual(sheet.minX, window.minX, "\(width) pt: not stranded off the leading edge")
            XCTAssertLessThanOrEqual(sheet.maxX, window.maxX + 1, "\(width) pt: not clipped at the trailing edge")
            app.terminate()
        }
    }

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
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(done.frame, before, "The narrow sheet has one size: a drag changes no detent")
        XCTAssertTrue(app.descendants(matching: .any)["home-manage-state"].exists)
    }

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
        Thread.sleep(forTimeInterval: 1)
    }

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

    private func assertTrailingColumn(_ sheet: CGRect, in window: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(sheet.minX, window.midX, "The sheet occupies a trailing column, not the middle: \(sheet) in \(window)", file: file, line: line)
        XCTAssertGreaterThan(sheet.maxX, window.maxX - 48, "The sheet sits at the trailing edge: \(sheet) in \(window)", file: file, line: line)
        XCTAssertLessThan(sheet.minY, window.minY + window.height * 0.2, "The column is full height, not a medium detent: \(sheet) in \(window)", file: file, line: line)
    }

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
