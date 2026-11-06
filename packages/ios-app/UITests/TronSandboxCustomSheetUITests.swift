import XCTest

/// Settings → Setup → Sandbox → Custom sheet (#2302): the playground opens, the
/// fluid sheet presents at its content's height, grows with added rows up to a
/// cap below the status bar, and closes through Done, a downward drag and the
/// dimmed backdrop. Fake data only; the Settings fixture's Gateway is untouched.
final class TronSandboxCustomSheetUITests: XCTestCase {
    @MainActor func testSandboxCustomSheetPresentsResizesAndDismisses() {
        continueAfterFailure = false
        let app = openStage(dark: false, large: false)
        defer { app.terminate() }
        let window = app.windows.firstMatch.frame

        let sheet = presentCustom(app)
        let few = sheet.frame
        XCTAssertEqual(few.maxY, window.maxY - 8, accuracy: 2, "The card floats 8 points above the bottom edge")
        XCTAssertLessThan(few.height, window.height * 0.75, "Two rows: the card fits its content, not a detent")
        keep(app, "2302-custom-few-light")

        // Adding rows grows the card with its content; past the cap it stops below the status bar.
        for _ in 0..<4 { app.buttons["sandbox-rows-add"].tap() }
        settle(sheet)
        let more = sheet.frame
        XCTAssertGreaterThan(more.height, few.height + 100, "\(few) → \(more)")
        XCTAssertEqual(more.maxY, few.maxY, accuracy: 1, "The card grows upward from its bottom edge")
        for _ in 0..<10 { app.buttons["sandbox-rows-add"].tap() }
        app.buttons["sandbox-sections-toggle"].tap()
        settle(sheet)
        let capped = sheet.frame
        XCTAssertGreaterThan(capped.minY, 40, "The cap keeps the card clear of the status bar: \(capped)")
        XCTAssertEqual(app.staticTexts["sandbox-rows-count"].label, "14 rows")
        keep(app, "2302-custom-many-light")
        // Past the cap the body scrolls inside a card that stays put.
        let firstRow = app.buttons["sandbox-row-0"]
        let rowTop = firstRow.frame.minY
        let content = window.height * 0.55
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            .press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7 - 200 / window.height)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        settle(sheet, firstRow)
        XCTAssertLessThan(firstRow.frame.minY, rowTop - 100, "The content scrolled")
        XCTAssertEqual(sheet.frame.minY, capped.minY, accuracy: 1, "The card did not move while the content scrolled")
        // Dragging down scrolls the content back to its top, then moves the sheet; a slow
        // release returns it to rest with the content at its top.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: content / window.height))
            .press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)),
                   withVelocity: .slow, thenHoldForDuration: 0.5)
        settle(sheet, firstRow)
        XCTAssertEqual(firstRow.frame.minY, rowTop, accuracy: 1, "The content is back at its top")
        XCTAssertEqual(sheet.frame.minY, capped.minY, accuracy: 1, "The released card returned to rest")
        // Removing rows shrinks it again.
        for _ in 0..<14 { app.buttons["sandbox-rows-remove"].tap() }
        app.buttons["sandbox-sections-toggle"].tap()
        settle(sheet)
        XCTAssertLessThan(sheet.frame.height, few.height, "No rows: smaller than two rows")

        // Done closes it.
        app.buttons["sandbox-sheet-done"].tap()
        XCTAssertTrue(waitForAbsence(sheet), app.debugDescription)

        // A downward fling from the header closes it.
        let dragged = presentCustom(app)
        let title = app.staticTexts["sandbox-sheet-title"]
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)),
                   withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(waitForAbsence(dragged), app.debugDescription)

        // A short slow drag is not a dismissal: the card springs back.
        let held = presentCustom(app)
        let rest = held.frame
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 2.5)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        settle(held)
        XCTAssertTrue(held.exists)
        XCTAssertEqual(held.frame.minY, rest.minY, accuracy: 1, "The card returns to rest")

        // Tapping the dim above the card closes it (below the status bar, which owns its own taps).
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        XCTAssertTrue(waitForAbsence(held), app.debugDescription)

        app.buttons["sandbox-stage-close"].tap()
        XCTAssertTrue(app.buttons["sandbox-experiment-custom-sheet"].waitForExistence(timeout: 5), app.debugDescription)
    }

    /// The same present-then-fling sequence on the stock sheet and the fluid
    /// sheet, read from the stage's frame meter. Coordinates are resolved once,
    /// before measuring, so no accessibility query runs inside a measured window.
    @MainActor func testSandboxSheetFrameMeterBaseline() {
        continueAfterFailure = false
        let app = openStage(dark: false, large: false)
        defer { app.terminate() }
        let window = app.windows.firstMatch
        let stock = app.buttons["sandbox-present-stock"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let custom = app.buttons["sandbox-present-custom"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let grab = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.66))
        let away = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99))
        for round in 1...3 {
            for (name, button) in [("stock", stock), ("custom", custom)] {
                button.tap()
                Thread.sleep(forTimeInterval: 1.5)
                grab.press(forDuration: 0.05, thenDragTo: away, withVelocity: .fast, thenHoldForDuration: 0)
                // The meter's 4 s window started at the present.
                Thread.sleep(forTimeInterval: 3)
                record(app, "\(name)-\(round)")
            }
        }
    }

    /// One continuous take for review: XCTest's screen recording of this run is
    /// the approval video. Present, a held drag that springs back, a fling
    /// dismissal, content-driven resizing, an in-sheet push, then in 4× slow
    /// motion a present caught mid-flight and a dismissal caught and reversed,
    /// and finally the stock sheet. Positions are resolved at rest.
    @MainActor func testSandboxCustomSheetMotionTake() {
        continueAfterFailure = false
        let app = openStage(dark: false, large: false)
        defer { app.terminate() }
        let window = app.windows.firstMatch
        func at(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
            window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
        }
        func center(_ element: XCUIElement) -> XCUICoordinate {
            let frame = element.frame
            return at(frame.midX, frame.midY)
        }
        let present = center(app.buttons["sandbox-present-custom"])
        let stock = center(app.buttons["sandbox-present-stock"])
        let slow = app.switches["sandbox-slow-motion"]
        let slowSwitch = at(slow.frame.maxX - 30, slow.frame.midY)
        let bottom = window.frame.maxY

        present.tap()
        _ = app.buttons["sandbox-sheet-done"].waitForExistence(timeout: 5)
        Thread.sleep(forTimeInterval: 1.2)
        let title = app.staticTexts["sandbox-sheet-title"].frame
        let grab = at(title.midX, title.midY)
        let add = center(app.buttons["sandbox-rows-add"])
        let remove = center(app.buttons["sandbox-rows-remove"])
        let sections = center(app.buttons["sandbox-sections-toggle"])

        // A held drag springs back; a short upward pull rubber-bands.
        grab.press(forDuration: 0.1, thenDragTo: at(title.midX, title.midY + 180), withVelocity: .slow, thenHoldForDuration: 0.6)
        Thread.sleep(forTimeInterval: 1.0)
        grab.press(forDuration: 0.1, thenDragTo: at(title.midX, title.midY - 160), withVelocity: .slow, thenHoldForDuration: 0.4)
        Thread.sleep(forTimeInterval: 1.0)
        // A fling dismisses with the finger's velocity.
        grab.press(forDuration: 0.05, thenDragTo: at(title.midX, bottom - 4), withVelocity: .fast, thenHoldForDuration: 0)
        Thread.sleep(forTimeInterval: 1.2)

        // Content-driven resizing: rows and sections in and out.
        present.tap()
        Thread.sleep(forTimeInterval: 1.2)
        for _ in 0..<5 { add.tap(); Thread.sleep(forTimeInterval: 0.35) }
        sections.tap()
        Thread.sleep(forTimeInterval: 1.0)
        let row = app.buttons["sandbox-row-2"].frame
        at(row.midX, row.midY).tap()
        Thread.sleep(forTimeInterval: 1.4)
        let back = app.buttons["sandbox-sheet-back"].frame
        at(back.midX, back.midY).tap()
        Thread.sleep(forTimeInterval: 1.0)
        sections.tap()
        Thread.sleep(forTimeInterval: 0.6)
        for _ in 0..<5 { remove.tap(); Thread.sleep(forTimeInterval: 0.35) }
        Thread.sleep(forTimeInterval: 0.8)
        let done = app.buttons["sandbox-sheet-done"].frame
        at(done.midX, done.midY).tap()
        Thread.sleep(forTimeInterval: 1.2)

        // 4× slow motion: catch the present mid-flight and throw it back up.
        slowSwitch.tap()
        Thread.sleep(forTimeInterval: 0.6)
        present.tap()
        at(window.frame.midX, bottom - 140).press(forDuration: 0.05, thenDragTo: at(window.frame.midX, bottom - 60),
                                                    withVelocity: .slow, thenHoldForDuration: 0.3)
        Thread.sleep(forTimeInterval: 3.0)
        // Catch the dismissal and pull it back: it presents again from where it was caught.
        at(window.frame.midX, 140).tap()
        at(window.frame.midX, bottom - 40).press(forDuration: 0.05, thenDragTo: at(window.frame.midX, bottom - 380),
                                                  withVelocity: .fast, thenHoldForDuration: 0)
        Thread.sleep(forTimeInterval: 3.0)
        at(done.midX, done.midY).tap()
        Thread.sleep(forTimeInterval: 2.5)
        slowSwitch.tap()
        Thread.sleep(forTimeInterval: 0.6)

        // The stock sheet with the same content, for comparison.
        stock.tap()
        Thread.sleep(forTimeInterval: 1.5)
        for _ in 0..<5 { add.tap(); Thread.sleep(forTimeInterval: 0.35) }
        Thread.sleep(forTimeInterval: 1.0)
        at(window.frame.midX, window.frame.midY + 120).press(forDuration: 0.05, thenDragTo: at(window.frame.midX, bottom - 4),
                                                            withVelocity: .fast, thenHoldForDuration: 0)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(app.buttons["sandbox-present-custom"].isHittable, app.debugDescription)
    }

    /// Visual review captures (light, dark, accessibility XXXL; few and many rows,
    /// a pushed detail page) with the stock sheet beside them.
    @MainActor func testSandboxCustomSheetReviewCaptures() {
        continueAfterFailure = false
        for (name, dark, large) in [("light", false, false), ("dark", true, false), ("xxxl", false, true)] {
            let app = openStage(dark: dark, large: large)
            keep(app, "2302-stage-\(name)")
            _ = presentCustom(app)
            keep(app, "2302-custom-few-\(name)")
            for _ in 0..<12 { app.buttons["sandbox-rows-add"].tap() }
            app.buttons["sandbox-sections-toggle"].tap()
            settle()
            keep(app, "2302-custom-many-\(name)")
            app.buttons["sandbox-row-1"].tap()
            settle()
            keep(app, "2302-custom-detail-\(name)")
            app.buttons["sandbox-sheet-back"].tap()
            for _ in 0..<12 { app.buttons["sandbox-rows-remove"].tap() }
            app.buttons["sandbox-sections-toggle"].tap()
            app.buttons["sandbox-sheet-done"].tap()
            XCTAssertTrue(waitForAbsence(fluidSheet(app)), app.debugDescription)

            app.buttons["sandbox-present-stock"].tap()
            XCTAssertTrue(app.buttons["sandbox-stock-done"].waitForExistence(timeout: 5), app.debugDescription)
            settle()
            keep(app, "2302-stock-few-\(name)")
            app.buttons["sandbox-stock-done"].tap()
            XCTAssertTrue(app.buttons["sandbox-present-custom"].waitForExistence(timeout: 5))
            settle()
            app.terminate()
        }
    }

    @MainActor private func openStage(dark: Bool, large: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture"] + (dark ? ["-settings-renderer-dark"] : [])
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        let setup = app.buttons["settings-link-Setup"]
        XCTAssertTrue(setup.waitForExistence(timeout: 15), app.debugDescription)
        for _ in 0..<8 where !setup.isHittable { app.swipeUp() }
        setup.tap()
        let sandbox = app.buttons["settings-link-Sandbox"]
        XCTAssertTrue(sandbox.waitForExistence(timeout: 8), app.debugDescription)
        for _ in 0..<10 where !sandbox.isHittable { app.swipeUp() }
        sandbox.tap()
        let experiment = app.buttons["sandbox-experiment-custom-sheet"]
        XCTAssertTrue(experiment.waitForExistence(timeout: 8), app.debugDescription)
        experiment.tap()
        XCTAssertTrue(app.buttons["sandbox-present-custom"].waitForExistence(timeout: 8), app.debugDescription)
        settle()
        return app
    }

    @MainActor private func presentCustom(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["sandbox-present-custom"].tap()
        let sheet = fluidSheet(app)
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["sandbox-sheet-done"].waitForExistence(timeout: 5), app.debugDescription)
        settle(sheet)
        return sheet
    }

    /// The card is a modal container, which XCTest reports as an alert.
    @MainActor private func fluidSheet(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "fluid-sheet").firstMatch
    }

    private func settle() { Thread.sleep(forTimeInterval: 0.9) }

    /// Waits until the springs have come to rest: after a 0.45 s floor (so a
    /// motion that starts late is not read as rest), two consecutive reads,
    /// 150 ms apart, of every element's frame agree. Fails after 5 s rather
    /// than reading a frame mid-motion.
    @MainActor private func settle(_ elements: XCUIElement..., file: StaticString = #filePath, line: UInt = #line) {
        Thread.sleep(forTimeInterval: 0.45)
        var previous = elements.map(\.frame)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.15)
            let current = elements.map(\.frame)
            if current == previous { return }
            previous = current
        }
        XCTFail("Frames still moving after 5 s: \(previous)", file: file, line: line)
    }

    @MainActor private func waitForAbsence(_ element: XCUIElement) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: 5) == .completed
    }

    /// The frame meter's reading for the interactions since the last present.
    @MainActor private func record(_ app: XCUIApplication, _ name: String) {
        let meter = app.descendants(matching: .any).matching(identifier: "sandbox-frame-meter").firstMatch
        XCTAssertTrue(meter.waitForExistence(timeout: 3), app.debugDescription)
        var value = (meter.value as? String) ?? ""
        for _ in 0..<10 where value.contains("measuring") || value.isEmpty {
            Thread.sleep(forTimeInterval: 0.5)
            value = (meter.value as? String) ?? ""
        }
        XCTAssertFalse(value.contains("measuring"), value)
        let attachment = XCTAttachment(string: value)
        attachment.name = "2302-frames-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("2302-frames-\(name): \(value)")
    }

    @MainActor private func keep(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
