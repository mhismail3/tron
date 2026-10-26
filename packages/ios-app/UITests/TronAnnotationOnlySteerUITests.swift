import XCTest

/// Production ChatView over the fixture socket: an annotation is the queued
/// prompt's content, not a separate row above a header-only editor affordance.
@MainActor final class TronAnnotationOnlySteerUITests: XCTestCase {
    func testAnnotationOnlySteerBelongsToCardAndRemainsEditable() {
        for mode in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready",
                "-foreground-queued-editor", "-foreground-queued-steer",
                "-foreground-queued-annotation", "-themeColor", "burgundy"]
                + (mode == "dark" ? ["-home-dark"] : [])
            app.launch()
            defer { app.terminate() }
            let home = app.buttons["home-pinned-row"]
            guard home.waitForExistence(timeout: 15) else { XCTFail(app.debugDescription); return }
            home.tap()
            let annotation = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show annotation'")).firstMatch
            guard annotation.waitForExistence(timeout: 15) else { XCTFail(app.debugDescription); return }
            let arrow = app.buttons["arrow.turn.up.right"].firstMatch
            XCTAssertTrue(arrow.waitForExistence(timeout: 5), app.debugDescription)
            keep(app, "annotation-only-steer-\(mode)-card")
            XCTAssertGreaterThan(annotation.frame.minY, arrow.frame.maxY,
                "The annotation must be content beneath the queue header, inside its card, not detached above it")

            // The chip retains its own detail action, separate from editing the queue.
            annotation.tap()
            XCTAssertTrue(app.staticTexts["chat.annotation.comment"].waitForExistence(timeout: 5), app.debugDescription)
            app.buttons["Done"].firstMatch.tap()
            arrow.tap()
            let editor = app.textViews["Queued message"]
            guard editor.waitForExistence(timeout: 8) else { XCTFail(app.debugDescription); return }
            XCTAssertTrue((editor.value as? String ?? "").hasSuffix("</annotation>"), "The editor retains the annotation-only envelope")
            XCTAssertTrue(app.buttons["Save queued message"].isEnabled)
            XCTAssertTrue(app.buttons["Remove queued message"].isEnabled)
            keep(app, "annotation-only-steer-\(mode)-editor")
            app.terminate()
        }
    }

    private func keep(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
