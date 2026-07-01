import XCTest

final class DashboardV2UITests: XCTestCase {
    @MainActor
    func testDashboardV2SelectorAndOwnedLabSheet() throws {
        let app = XCUIApplication()
        app.launch()

        let selector = try XCTUnwrap(
            waitForFirstExisting(
                app.buttons["dashboard-mode-selector"].firstMatch,
                app.otherElements["dashboard-mode-selector"].firstMatch,
                timeout: 20
            ),
            "Dashboard selector should be visible"
        )
        selector.tap()

        let dashboardV2Option = app.staticTexts["Dashboard 2.0"].firstMatch
        XCTAssertTrue(dashboardV2Option.waitForExistence(timeout: 5), "Dashboard 2.0 option should appear")
        dashboardV2Option.tap()

        XCTAssertTrue(
            app.staticTexts["Sessions"].waitForExistence(timeout: 10),
            "Dashboard 2.0 surface should render"
        )
        keepScreenshot(named: "dashboard-v2-surface")

        let labButton = app.buttons["dashboard-v2-open-lab"].firstMatch
        XCTAssertTrue(labButton.waitForExistence(timeout: 10), "Owned lab button should be visible")
        assertNearlySquare(labButton, named: "Dashboard 2.0 lab button")
        tapVisibleEdge(labButton, dx: 0.88)

        XCTAssertTrue(app.staticTexts["Glass Lab"].waitForExistence(timeout: 10), "Owned lab sheet should appear")
        keepScreenshot(named: "dashboard-v2-lab-compact")

        let closeButton = app.buttons["Close component lab"].firstMatch
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5), "Owned lab close button should be visible")
        assertNearlySquare(closeButton, named: "Owned lab close button")

        let regularCircle = app.buttons["Lab regular circle"].firstMatch
        XCTAssertTrue(regularCircle.waitForExistence(timeout: 5), "Regular lab circle should be visible")
        assertNearlySquare(regularCircle, named: "Regular lab circle")

        let expandButton = app.buttons["Expand component lab"].firstMatch
        XCTAssertTrue(expandButton.waitForExistence(timeout: 5), "Owned lab detent button should be visible")
        assertNearlySquare(expandButton, named: "Owned lab detent button")

        dragSheetUp(in: app)
        XCTAssertTrue(
            app.staticTexts["Owned sheet chrome · Expanded"].waitForExistence(timeout: 5),
            "Dragging the owned lab sheet upward should expand its app-owned detent"
        )
        keepScreenshot(named: "dashboard-v2-lab-expanded")

        tapVisibleEdge(closeButton, dx: 0.14)
        XCTAssertFalse(app.staticTexts["Glass Lab"].waitForExistence(timeout: 2), "Owned lab sheet should close from an edge tap")
    }

    @MainActor
    private func waitForFirstExisting(_ elements: XCUIElement..., timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for element in elements where element.exists {
                return element
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        for element in elements where element.exists {
            return element
        }
        return nil
    }

    @MainActor
    private func tapVisibleEdge(
        _ element: XCUIElement,
        dx: CGFloat,
        dy: CGFloat = 0.5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "Element should exist before edge tap", file: file, line: line)
        element.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy)).tap()
    }

    @MainActor
    private func assertNearlySquare(
        _ element: XCUIElement,
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(name) should exist", file: file, line: line)
        let frame = element.frame
        XCTAssertLessThanOrEqual(
            abs(frame.width - frame.height),
            1,
            "\(name) should expose a square hit frame, got \(frame)",
            file: file,
            line: line
        )
    }

    @MainActor
    private func dragSheetUp(in app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.52))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.22))
        start.press(forDuration: 0.06, thenDragTo: end)
    }

    @MainActor
    private func keepScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let directory = ProcessInfo.processInfo.environment["TRON_UI_SCREENSHOT_DIR"]
            ?? "/tmp/tron-ui-validation-screenshots"
        let url = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("\(name).png")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }
}
