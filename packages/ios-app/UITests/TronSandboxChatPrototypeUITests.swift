import XCTest

/// Settings → Setup → Sandbox → Chat · prototype (#2304): the transcript, the
/// composer and its send circle, the liquid action menu, the context panel, the
/// feedback cluster's sheet and its nested sheet, all with fake data. Each
/// overlay owns input while open and returns it when closed.
final class TronSandboxChatPrototypeUITests: XCTestCase {
    @MainActor func testChatPrototypeComponentsAndOverlays() {
        continueAfterFailure = false
        let app = openChat(dark: false, large: false)
        defer { app.terminate() }

        // The transcript opens at its end: the last tool run sits above the composer.
        let lastRun = app.buttons["chat-proto-tools-8"]
        XCTAssertTrue(lastRun.waitForExistence(timeout: 5), app.debugDescription)
        let composer = app.textViews["chat-proto-composer"].exists ? app.textViews["chat-proto-composer"] : app.textFields["chat-proto-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertLessThan(lastRun.frame.maxY, composer.frame.minY, "The last row clears the floating controls")

        // A tool run expands in place.
        lastRun.tap()
        XCTAssertEqual(lastRun.value as? String, "Expanded")
        lastRun.tap()

        // Typing turns the action circle into Send; sending appends and clears the draft.
        composer.tap()
        composer.typeText("Ship it")
        let send = app.buttons["chat-proto-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 3), app.debugDescription)
        send.tap()
        XCTAssertTrue(app.staticTexts["Ship it"].waitForExistence(timeout: 3)
                      || app.descendants(matching: .any)["You: Ship it"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(send.waitForExistence(timeout: 1), "An empty draft shows the menu trigger again")

        // The liquid menu: closed, its actions take no input; open, they do.
        let menu = app.buttons["chat-proto-menu"]
        let task = app.buttons["chat-proto-menu-task"]
        XCTAssertFalse(task.isHittable, "A closed menu's actions are not targets")
        menu.tap()
        XCTAssertTrue(task.waitForExistence(timeout: 2) && waitHittable(task), app.debugDescription)
        XCTAssertGreaterThan(menu.frame.minY - task.frame.minY, 140, "The third action rises three steps above the trigger")
        XCTAssertEqual(menu.label, "Close actions")
        task.tap()
        XCTAssertFalse(waitHittable(task, timeout: 1.5), "Choosing an action closes the menu")
        let feedback = app.buttons["chat-proto-feedback"]
        XCTAssertTrue(feedback.waitForExistence(timeout: 3))
        XCTAssertEqual(feedback.value as? String, "Started a task", "The new event leads the feedback")

        // The feedback opens its sheet; a row opens a nested sheet over it.
        feedback.tap()
        let event = app.buttons["chat-proto-event-0"]
        XCTAssertTrue(event.waitForExistence(timeout: 3), app.debugDescription)
        event.tap()
        XCTAssertTrue(element(app, "chat-proto-event-detail").waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(event.isHittable, "Only the top sheet takes input")
        doneButtons(app).last?.tap()
        XCTAssertTrue(waitHittable(event), "Closing the nested sheet returns input to the list")
        doneButtons(app).last?.tap()
        XCTAssertTrue(waitForAbsence(event), app.debugDescription)

        // The context panel changes the header's choice, which the parent keeps.
        let context = app.buttons["chat-proto-context"]
        context.tap()
        let garden = app.buttons["chat-proto-context-2"]
        XCTAssertTrue(garden.waitForExistence(timeout: 3), app.debugDescription)
        garden.tap()
        XCTAssertTrue(waitForAbsence(garden), app.debugDescription)
        XCTAssertTrue(context.label.contains("Garden plan"), context.label)

        app.buttons["chat-proto-close"].tap()
        XCTAssertTrue(app.buttons["sandbox-experiment-chat"].waitForExistence(timeout: 5), app.debugDescription)
    }

    /// One continuous take for review (recorded by the caller's screen capture):
    /// scroll, a tool run expanding, the menu opening, reversed mid-open and
    /// closing, typing with the keyboard, the context panel, the updates sheet and
    /// its nested sheet. Evidence only; positions are resolved at rest.
    @MainActor func testChatPrototypeMotionTake() {
        continueAfterFailure = false
        let app = openChat(dark: false, large: false)
        defer { app.terminate() }
        let window = app.windows.firstMatch
        Thread.sleep(forTimeInterval: 1.0)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)),
                   withVelocity: .default, thenHoldForDuration: 0)
        Thread.sleep(forTimeInterval: 1.2)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)),
                   withVelocity: .default, thenHoldForDuration: 0)
        Thread.sleep(forTimeInterval: 1.2)
        let run = app.buttons["chat-proto-tools-8"]
        run.tap(); Thread.sleep(forTimeInterval: 1.0)
        run.tap(); Thread.sleep(forTimeInterval: 1.0)
        let menu = app.buttons["chat-proto-menu"]
        let trigger = menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        trigger.tap(); Thread.sleep(forTimeInterval: 1.2)
        trigger.tap(); Thread.sleep(forTimeInterval: 1.0)
        // Reverse mid-open: the second tap lands while the circles are still rising.
        trigger.tap(); Thread.sleep(forTimeInterval: 0.12); trigger.tap()
        Thread.sleep(forTimeInterval: 1.2)
        trigger.tap(); Thread.sleep(forTimeInterval: 1.0)
        app.buttons["chat-proto-menu-command"].tap()
        Thread.sleep(forTimeInterval: 3.6)
        let composer = app.textViews["chat-proto-composer"].exists ? app.textViews["chat-proto-composer"] : app.textFields["chat-proto-composer"]
        composer.tap(); Thread.sleep(forTimeInterval: 0.8)
        composer.typeText("Ship the retry fix")
        Thread.sleep(forTimeInterval: 0.6)
        app.buttons["chat-proto-send"].tap()
        Thread.sleep(forTimeInterval: 1.2)
        app.buttons["chat-proto-context"].tap(); Thread.sleep(forTimeInterval: 1.0)
        app.buttons["chat-proto-context-1"].tap(); Thread.sleep(forTimeInterval: 1.0)
        app.buttons["chat-proto-feedback"].tap(); Thread.sleep(forTimeInterval: 1.2)
        app.buttons["chat-proto-event-1"].tap(); Thread.sleep(forTimeInterval: 1.2)
        doneButtons(app).last?.tap(); Thread.sleep(forTimeInterval: 1.0)
        doneButtons(app).last?.tap(); Thread.sleep(forTimeInterval: 1.2)
        XCTAssertTrue(menu.isHittable)
    }

    /// Review captures for the visual-direction gate: light, dark and XXXL.
    @MainActor func testChatPrototypeReviewCaptures() {
        continueAfterFailure = false
        for (name, dark, large) in [("light", false, false), ("dark", true, false), ("xxxl", false, true)] {
            let app = openChat(dark: dark, large: large)
            Thread.sleep(forTimeInterval: 0.8)
            keep("2304-chat-\(name)")
            app.buttons["chat-proto-tools-8"].tap()
            Thread.sleep(forTimeInterval: 0.8)
            keep("2304-chat-tools-expanded-\(name)")
            app.buttons["chat-proto-tools-8"].tap()
            app.buttons["chat-proto-menu"].tap()
            Thread.sleep(forTimeInterval: 0.9)
            keep("2304-chat-menu-\(name)")
            app.buttons["chat-proto-menu"].tap()
            Thread.sleep(forTimeInterval: 0.6)
            let composer = app.textViews["chat-proto-composer"].exists ? app.textViews["chat-proto-composer"] : app.textFields["chat-proto-composer"]
            composer.tap()
            composer.typeText("Draft that survives the keyboard")
            Thread.sleep(forTimeInterval: 0.9)
            keep("2304-chat-keyboard-\(name)")
            app.buttons["chat-proto-context"].tap()
            Thread.sleep(forTimeInterval: 0.9)
            keep("2304-chat-context-panel-\(name)")
            app.buttons["chat-proto-context-0"].tap()
            Thread.sleep(forTimeInterval: 0.6)
            app.buttons["chat-proto-feedback"].tap()
            Thread.sleep(forTimeInterval: 1.0)
            keep("2304-chat-updates-sheet-\(name)")
            app.buttons["chat-proto-event-1"].tap()
            Thread.sleep(forTimeInterval: 1.0)
            keep("2304-chat-nested-sheet-\(name)")
            app.terminate()
        }
    }

    @MainActor private func openChat(dark: Bool, large: Bool) -> XCUIApplication {
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
        let experiment = app.buttons["sandbox-experiment-chat"]
        XCTAssertTrue(experiment.waitForExistence(timeout: 8), app.debugDescription)
        experiment.tap()
        XCTAssertTrue(app.buttons["chat-proto-menu"].waitForExistence(timeout: 8), app.debugDescription)
        return app
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor private func doneButtons(_ app: XCUIApplication) -> [XCUIElement] {
        app.buttons.matching(identifier: "chat-proto-sheet-done").allElementsBoundByIndex.filter(\.isHittable)
    }

    @MainActor private func waitHittable(_ element: XCUIElement, timeout: TimeInterval = 3) -> Bool {
        let hittable = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: element)
        return XCTWaiter().wait(for: [hittable], timeout: timeout) == .completed
    }

    @MainActor private func waitForAbsence(_ element: XCUIElement) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: 5) == .completed
    }

    @MainActor private func keep(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
