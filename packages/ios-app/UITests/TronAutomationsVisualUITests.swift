import XCTest

/// Review screenshots of the Automations list, detail, run detail and editor in
/// light and dark, and the list and detail at XXXL text. A visual record for
/// design review, not a validation gate; run it explicitly.
final class TronAutomationsVisualUITests: XCTestCase {
    @MainActor func testAutomationsSheetsReviewScreenshots() {
        continueAfterFailure = false
        executionTimeAllowance = 400
        for variant in ["light", "dark", "xxxl"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-automation-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            if variant == "dark" { app.launchArguments.append("-automation-dark") }
            if variant == "xxxl" { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"] }
            app.launch()
            let menu = app.buttons["dashboard.menu"]
            XCTAssertTrue(menu.waitForExistence(timeout: 10), app.debugDescription)
            menu.tap()
            app.buttons["Automations"].tap()
            let card = app.buttons["automation-card.automation-2"]
            XCTAssertTrue(card.waitForExistence(timeout: 8), app.debugDescription)
            expand(app, title: "Automations")
            keep(app, "automations-list-\(variant)")

            card.tap()
            XCTAssertTrue(app.otherElements["automation-detail-summary"].waitForExistence(timeout: 8), app.debugDescription)
            Thread.sleep(forTimeInterval: 1)
            keep(app, "automation-detail-top-\(variant)")
            app.swipeUp(); Thread.sleep(forTimeInterval: 0.5)
            keep(app, "automation-detail-middle-\(variant)")
            for _ in 0..<6 { app.swipeUp() }
            Thread.sleep(forTimeInterval: 0.5)
            keep(app, "automation-detail-end-\(variant)")
            guard variant != "xxxl" else { app.terminate(); continue }

            let run = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Succeeded")).firstMatch
            XCTAssertTrue(run.waitForExistence(timeout: 5), app.debugDescription)
            run.tap()
            XCTAssertTrue(app.staticTexts["Run Details"].waitForExistence(timeout: 8), app.debugDescription)
            Thread.sleep(forTimeInterval: 1)
            keep(app, "automation-run-top-\(variant)")
            for _ in 0..<4 { app.swipeUp() }
            Thread.sleep(forTimeInterval: 0.5)
            keep(app, "automation-run-end-\(variant)")
            // The topmost sheet's Done is the last one in the hierarchy.
            let done = app.buttons.matching(NSPredicate(format: "label == 'Done'"))
            done.element(boundBy: done.count - 1).tap()
            XCTAssertTrue(app.staticTexts["Run Details"].waitForNonExistence(timeout: 5))

            let edit = app.buttons["Edit"]
            for _ in 0..<6 where !edit.isHittable { app.swipeDown() }
            XCTAssertTrue(edit.isHittable, app.debugDescription)
            edit.tap()
            XCTAssertTrue(app.navigationBars.staticTexts["Edit Automation"].firstMatch.waitForExistence(timeout: 8), app.debugDescription)
            Thread.sleep(forTimeInterval: 1.5)
            keep(app, "automation-edit-top-\(variant)")
            app.swipeUp(); Thread.sleep(forTimeInterval: 0.5)
            keep(app, "automation-edit-middle-\(variant)")
            app.swipeUp(); Thread.sleep(forTimeInterval: 0.5)
            keep(app, "automation-edit-lower-\(variant)")
            for _ in 0..<4 { app.swipeUp() }
            Thread.sleep(forTimeInterval: 0.5)
            keep(app, "automation-edit-end-\(variant)")
            app.terminate()
        }
    }

    @MainActor private func keep(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func expand(_ app: XCUIApplication, title text: String) {
        let title = app.navigationBars.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 8), app.debugDescription)
        Thread.sleep(forTimeInterval: 1)
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        for _ in 0..<4 where title.frame.minY > 120 {
            origin.withOffset(CGVector(dx: 60, dy: title.frame.midY))
                .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: 60, dy: 20)))
            Thread.sleep(forTimeInterval: 0.6)
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
}
