import XCTest

/// Real hosted app/socket journeys. PNGs are synthetic simulator proof, not device captures.
final class TronHomeTaskHistoryUITests: XCTestCase {
    @MainActor func testBeforeLight() { before(dark: false) }
    @MainActor func testBeforeDark() { before(dark: true) }
    @MainActor func testStructuredWhitespaceSections() {
        let app = launch(dark: false); defer { app.terminate() }
        open(app, "home-manage-tasks", ready: "home-task-active", done: "home-sheet-done-tasks")
        open(app, "home-task-active", ready: "home-task-detail", done: "home-sheet-done-task")
        let done = element(app, "home-task-checkin-done")
        XCTAssertTrue(done.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(done.label.contains("Clean 99a69ce97") && done.label.contains("rc65 uncapped 289.538s"), done.label)
        XCTAssertTrue(element(app, "home-task-checkin-next").label.contains("same 4 light/dark"))
    }
    @MainActor func testStructuredCheckinWhitespaceAndHistoryLight() { verify(dark: false) }
    @MainActor func testStructuredCheckinWhitespaceAndHistoryDark() { verify(dark: true) }
    @MainActor func testDisableHomeIconIsDestructiveRedInBothAppearances() {
        for dark in [false, true] {
            let app = launch(dark: dark); defer { app.terminate() }
            let row = element(app, "home-manage-disable")
            for _ in 0..<4 where !row.isHittable { app.swipeUp() }
            let image = XCUIScreen.main.screenshot().image.cgImage!
            let scale = CGFloat(image.width) / app.frame.width
            var area = row.frame; area.size.width = 50
            let crop = image.cropping(to: area.applying(CGAffineTransform(scaleX: scale, y: scale)))!
            var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
            CGContext(data: &pixels, width: crop.width, height: crop.height, bitsPerComponent: 8,
                      bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                .draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            let red = stride(from: 0, to: pixels.count, by: 4).filter {
                Double(pixels[$0]) > Double(pixels[$0 + 1]) * 1.4 && Double(pixels[$0]) > Double(pixels[$0 + 2]) * 1.4 && pixels[$0] > 60
            }.count
            XCTAssertGreaterThan(red, 20, "The decorative icon paints destructive red, not inherited green")
        }
    }
    @MainActor func testTaskFilterKeepsSupersededOperationsInHistoryOnly() {
        let app = launch(dark: false); defer { app.terminate() }
        open(app, "home-manage-tasks", ready: "home-task-active", done: "home-sheet-done-tasks")
        element(app, "home-tasks-filter").tap()
        app.buttons["All tasks"].firstMatch.tap()
        XCTAssertTrue(element(app, "home-task-active").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "home-task-terminal").exists)
        element(app, "home-tasks-filter").tap()
        app.buttons["Finished"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["No tasks"].waitForExistence(timeout: 5))
        element(app, "home-tasks-filter").tap()
        app.buttons["In progress"].firstMatch.tap()
        XCTAssertTrue(element(app, "home-task-active").waitForExistence(timeout: 5))
    }

    @MainActor private func launch(dark: Bool) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-task-history-review"] + (dark ? ["-home-dark"] : [])
        app.launch()
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 15))
        app.buttons["home-pinned-row"].tap()
        let context = app.buttons["session-context-button"]
        XCTAssertTrue(context.waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: context)], timeout: 10), .completed)
        context.tap()
        XCTAssertTrue(element(app, "home-manage-state").waitForExistence(timeout: 10))
        expand(app, done: "home-sheet-done-manage")
        return app
    }
    @MainActor private func before(dark: Bool) {
        let app = launch(dark: dark); defer { app.terminate() }
        let name = dark ? "dark" : "light"
        for _ in 0..<4 where !element(app, "home-manage-disable").isHittable { app.swipeUp() }
        shot("2073-before-manage-\(name)")
        app.swipeDown()
        open(app, "home-manage-tasks", ready: "home-task-active", done: "home-sheet-done-tasks")
        shot("2073-before-tasks-\(name)")
        open(app, "home-task-active", ready: "home-task-detail", done: "home-sheet-done-task")
        shot("2073-before-detail-\(name)")
    }
    @MainActor private func verify(dark: Bool) {
        let app = launch(dark: dark); defer { app.terminate() }
        let name = dark ? "dark" : "light"
        for _ in 0..<4 where !element(app, "home-manage-disable").isHittable { app.swipeUp() }
        shot("2073-after-manage-\(name)")
        app.swipeDown()
        open(app, "home-manage-tasks", ready: "home-task-active", done: "home-sheet-done-tasks")
        XCTAssertFalse(element(app, "home-task-terminal").exists, "A superseded needs-input operation is not another open task")
        shot("2073-after-tasks-\(name)")
        open(app, "home-task-active", ready: "home-task-detail", done: "home-sheet-done-task")
        let done = element(app, "home-task-checkin-done")
        XCTAssertTrue(done.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(done.label.contains("Clean 99a69ce97") && done.label.contains("rc65 uncapped 289.538s"), done.label)
        XCTAssertTrue(element(app, "home-task-checkin-next").label.contains("same 4 light/dark"))
        XCTAssertTrue(element(app, "home-task-checkin-blocked").label.contains("Maintainer visual approval needed."))
        let time = element(app, "home-task-checkin-time")
        XCTAssertTrue(time.exists)
        shot("2073-after-summary-\(name)")
        time.tap()
        XCTAssertTrue(element(app, "home-task-checkin-absolute-time").waitForExistence(timeout: 5))
        shot("2073-after-time-\(name)")
        app.navigationBars.staticTexts["Tasks"].firstMatch.tap()
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element(app, "home-task-checkin-absolute-time"))], timeout: 3)
        app.swipeUp(velocity: .slow)
        shot("2073-after-detail-\(name)")
        for _ in 0..<4 where !element(app, "home-task-view-checkins").isHittable { app.swipeUp() }
        open(app, "home-task-view-checkins", ready: "home-task-history-viewport", done: "home-sheet-done-task-history")
        XCTAssertTrue(element(app, "history-checkin-22").exists)
        shot("2073-after-history-\(name)")
        for _ in 0..<35 where !element(app, "operation-1").isHittable { app.swipeUp(velocity: .fast) }
        XCTAssertTrue(element(app, "history-checkin-0").exists, "History pages beyond the recent twelve snapshots")
        for _ in 0..<10 where !element(app, "operation-2").isHittable { app.swipeDown(velocity: .fast) }
        XCTAssertTrue(element(app, "operation-2").exists, "A resume with no check-ins remains in history")
        shot("2073-after-history-empty-operation-\(name)")
        for _ in 0..<10 where !element(app, "operation-1").isHittable { app.swipeUp(velocity: .fast) }
        XCTAssertTrue(element(app, "operation-1").exists)
        shot("2073-after-history-oldest-\(name)")
    }
    @MainActor private func open(_ app: XCUIApplication, _ id: String, ready: String, done: String) {
        let row = element(app, id)
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()
        XCTAssertTrue(element(app, ready).waitForExistence(timeout: 10), app.debugDescription)
        expand(app, done: done)
    }
    @MainActor private func expand(_ app: XCUIApplication, done id: String) {
        let done = app.buttons[id].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        guard done.frame.minY > 120 else { return }
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: 60, dy: done.frame.midY)).press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: 60, dy: 20)))
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "frame.minY < 120"), object: done)], timeout: 3)
    }
    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    @MainActor private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
