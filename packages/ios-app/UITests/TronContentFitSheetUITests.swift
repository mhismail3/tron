import XCTest

@MainActor final class TronContentFitSheetUITests: XCTestCase {
    func testSheetsFitContentOrOpenLarge() {
        continueAfterFailure = false
        for large in [false, true] {
            for (surface, fits) in [("worker-tools-short", true), ("worker-identities", false),
                                    ("worker-thinking", true), ("worker-thinking-long", false)] {
                let app = XCUIApplication()
                app.launchArguments = ["-tron-settings-fixture", "-settings-expanded-review", "-six-ui-surface", surface,
                                       "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
                    + (large ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : [])
                app.launch()
                let done = app.buttons.matching(NSPredicate(format: "label == 'Done'")).firstMatch
                XCTAssertTrue(done.waitForExistence(timeout: 15), app.debugDescription)
                sleep(1)
                let window = app.windows.firstMatch.frame.height
                if fits && !large {
                    XCTAssertGreaterThan(done.frame.minY, window * 0.4, "\(surface) fits and opens at content height")
                } else {
                    XCTAssertLessThan(done.frame.minY, 120, "\(surface) overflows or is XXXL and opens large")
                }
                attach(app, "fit-\(surface)-\(large ? "xxxl" : "standard")")
                app.terminate()
            }
        }
        for large in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
                + (large ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : [])
            app.launch()
            XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 15))
            app.buttons["home-pinned-row"].tap()
            let context = app.buttons["session-context-button"]
            XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: context)], timeout: 10) == .completed)
            context.tap()
            XCTAssertTrue(app.descendants(matching: .any)["home-manage-state"].waitForExistence(timeout: 8), app.debugDescription)
            sleep(1)
            attach(app, "fit-manage-home-\(large ? "xxxl" : "standard")")
            app.terminate()
        }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
