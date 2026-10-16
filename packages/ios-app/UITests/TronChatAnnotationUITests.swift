import XCTest

/// Select → annotate → chip → edit → send, on the real ChatView over the
/// annotation fixture socket (#899). Screenshots are kept as attachments.
final class TronChatAnnotationUITests: XCTestCase {
    @MainActor func testSelectionAcrossMarkdownBlocksCanBeAnnotated() {
        continueAfterFailure = false
        let app = launch(); defer { app.terminate() }

        let paragraph = assistantBlock(app, containing: "exponential backoff")
        let listItem = assistantBlock(app, containing: "Accepted prompts continue")
        XCTAssertTrue(listItem.waitForExistence(timeout: 5), app.debugDescription)
        let start = paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5))
        let end = listItem.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
        start.press(forDuration: 1.0, thenDragTo: end)

        let annotate = menuAction(app, "Annotate")
        XCTAssertTrue(annotate.waitForExistence(timeout: 5), app.debugDescription)
        annotate.tap()
        let bubble = app.otherElements["chat.annotation.bubble"]
        XCTAssertTrue(bubble.waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["Save annotation"].firstMatch.tap()

        let chip = app.otherElements.matching(identifier: "composer.staged-chip").firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(chip.label.contains("exponential backoff"), chip.label)
        XCTAssertTrue(chip.label.contains("Accepted prompts"), chip.label)
    }

    @MainActor func testAnnotateSelectionEditChipAndSend() {
        continueAfterFailure = false
        let app = launch(); defer { app.terminate() }

        // Native range selection on a completed assistant paragraph.
        let paragraph = assistantBlock(app, containing: "exponential backoff")
        let start = paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.12))
        let end = paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.83, dy: 0.12))
        start.press(forDuration: 1.0, thenDragTo: end)
        let annotate = menuAction(app, "Annotate")
        XCTAssertTrue(annotate.waitForExistence(timeout: 5), app.debugDescription)
        keepScreenshot(app, "899-1-selection")
        annotate.tap()

        // The bubble opens with the keyboard up and the quote it annotates.
        let bubble = app.otherElements["chat.annotation.bubble"]
        XCTAssertTrue(bubble.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "The comment field takes focus")
        dismissKeyboardTip(app)
        app.typeText("Make the cap configurable")
        keepScreenshot(app, "899-2-bubble-keyboard")
        XCTAssertLessThan(bubble.frame.maxY, app.keyboards.firstMatch.frame.minY, "The bubble stays above the keyboard")
        app.buttons["Save annotation"].firstMatch.tap()
        XCTAssertTrue(wait(for: bubble, exists: false))

        // A second annotation from a list item; both become shared staged chips.
        let item = assistantBlock(app, containing: "Accepted prompts continue")
        item.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).press(forDuration: 1.0)
        let second = menuAction(app, "Annotate")
        XCTAssertTrue(second.waitForExistence(timeout: 5), app.debugDescription)
        second.tap()
        XCTAssertTrue(bubble.waitForExistence(timeout: 5))
        app.typeText("Also on Wi-Fi changes")
        app.buttons["Save annotation"].firstMatch.tap()
        XCTAssertTrue(wait(for: bubble, exists: false))

        let chips = app.otherElements.matching(identifier: "composer.staged-chip")
        XCTAssertTrue(wait { chips.count == 2 }, "Annotations use the shared composer staged chip: \(app.debugDescription)")
        let first = chips.element(boundBy: 0)
        XCTAssertTrue(first.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show annotation'")).firstMatch.exists)
        XCTAssertTrue(first.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Remove annotation'")).firstMatch.exists)
        XCTAssertEqual(first.frame.midY, chips.element(boundBy: 1).frame.midY, accuracy: 1, "Chips share one strip")
        if app.keyboards.firstMatch.exists { app.swipeDown() }
        keepScreenshot(app, "899-3-chips")

        // The chip opens the standard sheet: quote, editable comment, save.
        first.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show annotation'")).firstMatch.tap()
        let editor = app.textViews["Annotation comment"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.otherElements["chat.annotation.quote"].exists || app.staticTexts["chat.annotation.quote"].exists)
        XCTAssertTrue(app.buttons["Delete annotation"].exists)
        XCTAssertGreaterThan(app.buttons["Save annotation"].frame.minY, app.windows.firstMatch.frame.height * 0.35, "The sheet opens at medium")
        keepScreenshot(app, "899-4-sheet")
        // Place the caret after the existing comment.
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.9)).tap()
        dismissKeyboardTip(app)
        app.typeText(" up to a minute")
        app.buttons["Save annotation"].tap()
        XCTAssertTrue(wait(for: editor, exists: false))

        // Send: the model receives quote+comment context ahead of the message.
        app.textViews["Message input"].tap()
        app.typeText("Please revise the retry section.")
        app.buttons["Send message"].firstMatch.tap()
        let prompt = app.staticTexts["fixture.last-prompt"]
        XCTAssertTrue(wait { prompt.label.hasPrefix("<annotation>\n> ") }, prompt.label)
        XCTAssertTrue(prompt.label.contains("Make the cap configurable up to a minute\n</annotation>"), prompt.label)
        XCTAssertTrue(prompt.label.contains("Also on Wi-Fi changes\n</annotation>"), prompt.label)
        XCTAssertTrue(prompt.label.hasSuffix("</annotation>\n\nPlease revise the retry section."), prompt.label)
        XCTAssertTrue(wait { chips.count == 0 }, "Sending clears staged annotations")

        // The sent message shows the annotations with the canonical chip and sheet.
        let sent = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show annotation'"))
        XCTAssertTrue(wait { sent.count == 2 }, app.debugDescription)
        keepScreenshot(app, "899-5-sent")
        sent.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["chat.annotation.comment"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Delete annotation"].exists, "Sent annotations are read-only")
        keepScreenshot(app, "899-6-sent-sheet")
    }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-chat-annotation-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(assistantBlock(app, containing: "exponential backoff").waitForExistence(timeout: 20), app.debugDescription)
        return app
    }

    @MainActor private func assistantBlock(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        // Completed assistant blocks keep the static-text accessibility shape.
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @MainActor private func menuAction(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ AND (elementType == %d OR elementType == %d)",
                                  title, XCUIElement.ElementType.menuItem.rawValue, XCUIElement.ElementType.button.rawValue))
            .firstMatch
    }

    /// The simulator's first-keyboard swipe-typing tip covers the keys.
    @MainActor private func dismissKeyboardTip(_ app: XCUIApplication) {
        let tip = app.buttons["Continue"]
        if tip.waitForExistence(timeout: 1) { tip.tap() }
    }

    private func wait(timeout: TimeInterval = 8, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    private func wait(for element: XCUIElement, exists: Bool) -> Bool {
        wait { element.exists == exists }
    }

    @MainActor private func keepScreenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
