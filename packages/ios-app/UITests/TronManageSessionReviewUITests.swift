import XCTest

final class TronManageSessionReviewUITests: XCTestCase {
    @MainActor func testSessionSettingsShowsProjectSection() {
        let app = launch(); defer { app.terminate() }
        let link = app.buttons["chat-settings-link"]
        for _ in 0..<12 where !link.isHittable { app.swipeUp() }
        link.tap()
        expandSheet(app, title: "Session Settings")
        let section = element(app, "session-project-settings")
        XCTAssertTrue(section.waitForExistence(timeout: 8), app.debugDescription)
        let none = element(app, "project-settings-no-overrides")
        XCTAssertTrue(none.waitForExistence(timeout: 8), app.debugDescription)
        for _ in 0..<6 where !none.isHittable { app.swipeUp() }
        XCTAssertFalse(labels(none, containing: "No repository overrides").isEmpty, none.debugDescription)
        XCTAssertLessThan(none.frame.height, 140, "No repository overrides is a row: \(none.frame)")
        XCTAssertTrue(section.buttons["project-settings-trust"].exists, section.debugDescription)
        XCTAssertTrue(labels(section, containing: "Workspace").isEmpty, "Manage Session's Workspace row already names the branch")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "settings-ignored-defaultTools").count, 1)
    }

    @MainActor private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-configuration-fixture", "-settings-scope-review", "-manage-session-review",
                               "-fixture-appearance", "light"]
        app.launch()
        XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 10))
        app.buttons["Stop session"].tap()
        XCTAssertTrue(element(app, "session-usage-summary").waitForExistence(timeout: 10), app.debugDescription)
        expandSheet(app, title: "Manage Session")
        return app
    }

    @MainActor private func labels(_ root: XCUIElement, containing text: String) -> [XCUIElement] {
        root.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).allElementsBoundByIndex
    }

    @MainActor private func expandSheet(_ app: XCUIApplication, title text: String) {
        let title = app.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 8), app.debugDescription)
        var last = title.frame.minY
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.3)
            if abs(title.frame.minY - last) < 0.5 { break }
            last = title.frame.minY
        }
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        for _ in 0..<3 where title.frame.minY > 120 {
            origin.withOffset(CGVector(dx: 60, dy: title.frame.midY))
                .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: 60, dy: 20)))
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "frame.minY < 120"), object: title)], timeout: 2)
        }
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }
}
