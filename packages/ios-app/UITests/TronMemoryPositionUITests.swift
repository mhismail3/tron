import XCTest

/// Real Home sheets and RPC fixture: catalog addresses, message counts and
/// summary positions deliberately differ. Captures are simulator review proof.
@MainActor final class TronMemoryPositionUITests: XCTestCase {
    func testScopedMemoryLight() { journey(dark: false, large: false) }
    func testScopedMemoryDark() { journey(dark: true, large: false) }
    func testScopedMemoryAccessibility() { journey(dark: false, large: true) }

    private func journey(dark: Bool, large: Bool) {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-memory-position-regression",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            + (dark ? ["-home-dark"] : [])
            + (large ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : [])
        app.launch(); defer { app.terminate() }
        let mode = large ? "accessibility" : dark ? "dark" : "light"
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        let ring = app.buttons["session-context-button"]
        XCTAssertTrue(ring.waitForExistence(timeout: 10)); ring.tap()
        expand(app, "Manage Home")
        reveal(app, "home-manage-chapters").tap()
        XCTAssertTrue(app.buttons["home-chapter-1"].waitForExistence(timeout: 10))
        expand(app, "Chapters")
        shot("chapters-list-\(mode)")
        app.buttons["home-chapter-1"].tap()
        XCTAssertTrue(element(app, "home-chapter-detail").waitForExistence(timeout: 10))
        expand(app, "Chapters")
        let browse = reveal(app, "home-chapter-browse-memory")
        shot("chapters-header-\(mode)")
        XCTAssertFalse(app.staticTexts["From Home's summaries of this chapter."].exists,
                       "Topics already names the chapter summaries; no redundant caption can scroll behind Chapters")
        browse.tap()
        XCTAssertTrue(app.buttons["home-memory-summary-7672-8"].waitForExistence(timeout: 10))
        expand(app, "Memory")
        checkChip(app, count: 32, mode: "scoped-\(mode)")
        app.buttons["home-sheet-done-memory"].tap()
        app.buttons["home-sheet-done-chapter"].tap()
        app.buttons["home-sheet-done-chapters"].tap()
        reveal(app, "home-manage-memory-browser").tap()
        XCTAssertTrue(app.buttons["home-memory-summary-7736-8"].waitForExistence(timeout: 10))
        expand(app, "Memory")
        checkChip(app, count: 40, mode: "unscoped-\(mode)")
    }

    private func checkChip(_ app: XCUIApplication, count: Int, mode: String) {
        let chip = app.buttons["feed-position-chip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        shot("memory-pill-\(mode)")
        // Assert semantics, not a particular number of visible rows or font layout.
        let label = chip.label
        let numbers = label.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init)
        XCTAssertTrue(label.hasPrefix("Items "), label)
        XCTAssertEqual(numbers.count, 3, label)
        if numbers.count == 3 {
            XCTAssertEqual(numbers[2], count, "Total counts this list's rows, never catalog messages")
            XCTAssertTrue((1...count).contains(numbers[0]) && (numbers[0]...count).contains(numbers[1]), label)
        }
        XCTAssertGreaterThanOrEqual(chip.frame.height, 44)
        XCTAssertLessThanOrEqual(chip.frame.width, app.windows.firstMatch.frame.width - 32)
        chip.tap()
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func reveal(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let target = element(app, id)
        XCTAssertTrue(target.waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<12 where !target.isHittable { app.swipeUp() }
        XCTAssertTrue(target.isHittable, app.debugDescription)
        return target
    }
    private func expand(_ app: XCUIApplication, _ title: String) {
        let heading = app.navigationBars.staticTexts[title].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        heading.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)))
    }
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
