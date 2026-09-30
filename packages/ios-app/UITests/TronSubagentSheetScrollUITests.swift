import XCTest

/// Physical gestures on the real managed sheet, not programmatic scroll offsets.
@MainActor
final class TronSubagentSheetScrollUITests: XCTestCase {
    func testEndContentAndHeaderGestures() { journey("end") }
    func testOriginContentAndHeaderGestures() { journey("origin") }

    func testContentGestureMatrix() throws {
        continueAfterFailure = true
        var measurements: [[String: Any]] = []
        for orientation in ["end", "origin"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-subagent-sheet-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launchEnvironment["TRON_CHAT_TRANSCRIPT_ORIENTATION"] = orientation
            app.launch()
            let open = app.buttons["Open subagent transcript"]
            XCTAssertTrue(open.waitForExistence(timeout: 15))
            for large in [false, true] {
                for down in [false, true] {
                    open.tap()
                    XCTAssertTrue(row(31, in: app).waitForExistence(timeout: 10))
                    let header = app.navigationBars.containing(.staticText, identifier: "Scroll worker").firstMatch
                    let scroll = app.scrollViews.firstMatch
                    if large {
                        header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
                            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
                    }
                    let phase = "\(orientation)-\(large ? "large" : "medium")-finger-\(down ? "down" : "up")"
                    let frame = scroll.frame
                    let headerY = header.frame.minY
                    let rowY = row(31, in: app).frame.minY
                    capture("matrix-\(phase)-before")
                    drag(app, scroll: scroll, down: down)
                    let dismissed = !header.exists
                    let moved = !row(31, in: app).isHittable || abs(row(31, in: app).frame.minY - rowY) > 20
                    let record: [String: Any] = ["phase": phase, "dismissed": dismissed,
                        "beforeHeaderY": headerY, "afterHeaderY": dismissed ? -1 : header.frame.minY,
                        "beforeHeight": frame.height, "afterHeight": dismissed ? 0 : scroll.frame.height,
                        "rowMoved": moved]
                    measurements.append(record)
                    print("CT23-CONTENT-MATRIX \(record)")
                    assertStationary(scroll, header: header, frame: frame, headerY: headerY, phase: phase)
                    if down { XCTAssertTrue(moved, "\(phase): older history must scroll") }
                    if !dismissed { app.buttons["Done"].tap() }
                    XCTAssertTrue(open.waitForExistence(timeout: 5))
                }
            }
            // Header-only behavior remains independent of content failures.
            open.tap()
            XCTAssertTrue(row(31, in: app).waitForExistence(timeout: 10))
            let header = app.navigationBars.containing(.staticText, identifier: "Scroll worker").firstMatch
            header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
            XCTAssertFalse(header.exists, "Header dismisses in \(orientation)")
            app.terminate()
        }
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys]),
                                       uniformTypeIdentifier: "public.json")
        attachment.name = "subagent-content-gesture-matrix.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func journey(_ orientation: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-subagent-sheet-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["TRON_CHAT_TRANSCRIPT_ORIENTATION"] = orientation
        app.launch()
        defer { app.terminate() }
        let open = app.buttons["Open subagent transcript"]
        XCTAssertTrue(open.waitForExistence(timeout: 15), app.debugDescription)
        open.tap()
        let newest = row(31, in: app)
        XCTAssertTrue(newest.waitForExistence(timeout: 10), app.debugDescription)
        let header = app.navigationBars.containing(.staticText, identifier: "Scroll worker").firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5), app.debugDescription)
        let scroll = app.scrollViews.firstMatch
        let medium = scroll.frame
        XCTAssertGreaterThan(header.frame.minY, app.frame.height * 0.35, "Must start at medium")
        capture("\(orientation)-medium-opening")
        exerciseContent(app, scroll: scroll, header: header, name: "\(orientation)-medium")

        // Only the title/toolbar region owns detent changes.
        header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
        XCTAssertGreaterThan(scroll.frame.height, medium.height + 100)
        exerciseContent(app, scroll: scroll, header: header, name: "\(orientation)-large")
        app.buttons["Done"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertFalse(header.exists)
        open.tap()
        XCTAssertTrue(newest.waitForExistence(timeout: 5))
        header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertFalse(header.exists, "Header swipe-down still dismisses")
        capture("\(orientation)-header-dismissed")
    }

    private func row(_ index: Int, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts["Child history row \(index). A bounded paragraph for scrolling."].firstMatch
    }

    private func exerciseContent(_ app: XCUIApplication, scroll: XCUIElement, header: XCUIElement, name: String) {
        let original = scroll.frame
        let headerY = header.frame.minY
        // Newest-edge overscroll is the flipped path's dismissal regression.
        drag(app, scroll: scroll, down: false)
        assertStationary(scroll, header: header, frame: original, headerY: headerY, phase: "\(name)-newest-edge")
        let newestY = row(31, in: app).frame.minY
        drag(app, scroll: scroll, down: true)
        assertStationary(scroll, header: header, frame: original, headerY: headerY, phase: "\(name)-older")
        XCTAssertTrue(!row(31, in: app).isHittable || abs(row(31, in: app).frame.minY - newestY) > 20,
                      "A content drag must actually move history")
        capture("\(name)-older")
        for _ in 0..<20 where !row(0, in: app).isHittable { drag(app, scroll: scroll, down: true) }
        XCTAssertTrue(row(0, in: app).isHittable, "Reach oldest history")
        for _ in 0..<2 { drag(app, scroll: scroll, down: true) }
        assertStationary(scroll, header: header, frame: original, headerY: headerY, phase: "\(name)-oldest-edge")
        for _ in 0..<20 where !row(31, in: app).isHittable { drag(app, scroll: scroll, down: false) }
        XCTAssertTrue(row(31, in: app).isHittable, "Return to newest history")
        for _ in 0..<2 { drag(app, scroll: scroll, down: false) }
        assertStationary(scroll, header: header, frame: original, headerY: headerY, phase: "\(name)-returned")
    }

    private func drag(_ app: XCUIApplication, scroll: XCUIElement, down: Bool) {
        // Window coordinates avoid reflecting the gesture with the native scroll view.
        XCTAssertTrue(scroll.exists, "Content edge drag must not dismiss the sheet")
        guard scroll.exists else { return }
        let frame = scroll.frame.intersection(app.frame)
        let start = CGPoint(x: frame.midX, y: frame.minY + frame.height * (down ? 0.3 : 0.8))
        let end = CGPoint(x: frame.midX, y: frame.minY + frame.height * (down ? 0.8 : 0.3))
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: start.x, dy: start.y)).press(forDuration: 0.1,
            thenDragTo: origin.withOffset(CGVector(dx: end.x, dy: end.y)))
    }

    private func assertStationary(_ scroll: XCUIElement, header: XCUIElement, frame: CGRect, headerY: CGFloat, phase: String) {
        capture(phase)
        XCTAssertTrue(header.exists, "\(phase): content must not dismiss")
        guard header.exists, scroll.exists else { return }
        XCTAssertEqual(header.frame.minY, headerY, accuracy: 1, phase)
        XCTAssertEqual(scroll.frame.minY, frame.minY, accuracy: 1, phase)
        XCTAssertEqual(scroll.frame.height, frame.height, accuracy: 1, phase)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
