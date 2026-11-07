import XCTest

/// Catch up from far back in the origin-anchored transcript (#330), on the
/// real ChatView over the haptics fixture socket. The staged frame must show
/// the reveal's gap above the newest end before the smooth final step, with
/// the keyboard up and with it down; the landing reaches the newest reply.
final class TronChatCatchUpUITests: XCTestCase {
    @MainActor func testStagedCatchUpKeepsItsRevealGapWithAndWithoutTheKeyboard() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-chat-haptics-fixture", "-chat-haptics-photos", "0",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); defer { app.terminate() }
        let composer = app.textViews["Message input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30), app.debugDescription)
        let status = app.staticTexts["fixture.gateway"]
        XCTAssertTrue(wait(status, "opens:1"), status.label)

        // Enough wrapped prompts and replies that the reader can scroll more
        // than the staged threshold (at least 320 points) away from the newest end.
        for index in 1...8 {
            composer.tap()
            composer.typeText("Catch-up prompt \(index): a long wrapped request that fills several lines of the transcript so the reader has history to scroll back through.")
            let send = app.buttons["Send message"]
            XCTAssertTrue(wait(send, "isEnabled == true", predicate: true), app.debugDescription)
            send.tap()
            XCTAssertTrue(wait(status, "prompts:\(index) "), status.label)
            XCTAssertTrue(wait(status, "phase:idle"), status.label)
        }

        let readout = app.descendants(matching: .any)["chat.hosted.catch-up-staged-gap"]
        XCTAssertTrue(readout.waitForExistence(timeout: 5), app.debugDescription)
        if app.keyboards.firstMatch.exists { app.buttons["Dismiss keyboard"].firstMatch.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10), "the keyboard is dismissed")
        for keyboardUp in [false, true] {
            // Read back with the keyboard down: an interactive drag over the
            // keyboard would dismiss it. The keyboard then opens over the
            // reader's position, which keeps Catch up.
            // The transcript fills the window between the title bar and the composer.
            let window = app.windows.firstMatch
            let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            let to = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            let catchUp = app.buttons["Catch up"]
            for _ in 0..<6 { from.press(forDuration: 0.05, thenDragTo: to) }
            XCTAssertTrue(catchUp.waitForExistence(timeout: 10), "the reader left the newest end: \(app.debugDescription)")
            if keyboardUp {
                composer.tap()
                XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the composer takes the keyboard")
                XCTAssertTrue(catchUp.exists, "opening the keyboard keeps the reader's position")
            }
            keepScreenshot(app, "330-before-catch-up-keyboard-\(keyboardUp ? "shown" : "hidden")")
            catchUp.tap()
            XCTAssertTrue(catchUp.waitForNonExistence(timeout: 10), "Catch up reached the newest end")
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Catch-up prompt 8")).firstMatch.waitForExistence(timeout: 5),
                          "the newest prompt is shown after Catch up")
            keepScreenshot(app, "330-catch-up-landed-keyboard-\(keyboardUp ? "shown" : "hidden")")
            if keyboardUp { XCTAssertTrue(app.keyboards.firstMatch.exists, "Catch up keeps the keyboard") }
            let after = readout.value as? String ?? ""
            let requested = Int(after.components(separatedBy: " ").first?.components(separatedBy: "=").last ?? "") ?? 0
            XCTAssertGreaterThan(requested, 320, "the reader was not far enough back to stage: \(after)")
            let gap = Int(after.components(separatedBy: "staged=").last ?? "")
            XCTAssertNotNil(gap, "Catch up did not stage its reveal: \(after)")
            XCTAssertGreaterThanOrEqual(gap ?? 0, 80,
                "keyboard \(keyboardUp ? "shown" : "hidden"): the staged frame lost its reveal gap to the bottom obstruction (\(after))")
        }
    }

    private func wait(_ element: XCUIElement, _ fragment: String, predicate: Bool = false, timeout: TimeInterval = 20) -> Bool {
        let condition = predicate ? NSPredicate(format: fragment) : NSPredicate(format: "label CONTAINS %@", fragment)
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: condition, object: element)], timeout: timeout) == .completed
    }

    @MainActor private func keepScreenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
