import XCTest

/// Select → annotate → chip → edit → send, on the real ChatView over the
/// annotation fixture socket (#899). Screenshots are kept as attachments.
final class TronChatAnnotationUITests: XCTestCase {
    @MainActor func testSelectionAcrossMarkdownBlocksCanBeAnnotated() {
        continueAfterFailure = false
        let app = launch(); defer { app.terminate() }

        let heading = assistantBlock(app, containing: "Retry policy")
        let listItem = assistantBlock(app, containing: "Accepted prompts continue")
        XCTAssertTrue(listItem.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertLessThan(heading.frame.midY, listItem.frame.midY, "Heading and list items keep separate accessibility frames")
        let start = heading.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5))
        // End inside the next item so the whole first item is selected; the
        // native end handle settles about a line above a drag's final point.
        let nextItem = assistantBlock(app, containing: "authoritative snapshot")
        let end = nextItem.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.9))
        start.press(forDuration: 1.0, thenDragTo: end)

        let annotate = menuAction(app, "Annotate")
        XCTAssertTrue(annotate.waitForExistence(timeout: 5), app.debugDescription)
        keepScreenshot(app, "1112-cross-block-selection")
        annotate.tap()
        let bubble = app.otherElements["chat.annotation.bubble"]
        XCTAssertTrue(bubble.waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["Save annotation"].firstMatch.tap()

        let chip = app.otherElements.matching(identifier: "composer.staged-chip").firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 5), app.debugDescription)
        chip.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show annotation'")).firstMatch.tap()
        // The sheet's combined quote can surface as either element type.
        let quote = app.descendants(matching: .any)["chat.annotation.quote"]
        XCTAssertTrue(quote.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(quote.label.contains("Retry policy"), quote.label)
        XCTAssertTrue(quote.label.contains("Accepted prompts continue on the Mac."), quote.label)
        keepScreenshot(app, "1112-cross-block-quote")
        app.buttons["Save annotation"].tap()
        XCTAssertTrue(wait(for: quote, exists: false))

        // Copy the same cross-heading/list range and paste it into the composer
        // so the journey verifies the plain-text markers and block separation.
        // Saving hands the keyboard to the composer; put it away first so the
        // list items are on screen for the drag.
        if app.keyboards.firstMatch.exists {
            // The transcript dismisses the keyboard interactively.
            let window = app.windows.firstMatch
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        }
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10), app.debugDescription)
        let startAgain = heading.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5))
        let endAgain = nextItem.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.9))
        startAgain.press(forDuration: 1.0, thenDragTo: endAgain)
        let copy = menuAction(app, "Copy")
        XCTAssertTrue(copy.waitForExistence(timeout: 5), app.debugDescription)
        copy.tap()
        let composer = app.textViews["Message input"]
        composer.tap()
        composer.press(forDuration: 1.0)
        let paste = menuAction(app, "Paste")
        XCTAssertTrue(paste.waitForExistence(timeout: 5), app.debugDescription)
        paste.tap()
        let pasted = composer.value as? String ?? ""
        XCTAssertTrue(pasted.contains("Retry policy"), pasted)
        XCTAssertTrue(pasted.contains("• Accepted prompts continue on the Mac."), pasted)
        XCTAssertTrue(pasted.contains("\n"), pasted)
        keepScreenshot(app, "1112-cross-block-copy-pasted")
        XCTAssertLessThan(try XCTUnwrap(pasted.range(of: "Retry policy")).lowerBound, try XCTUnwrap(pasted.range(of: "• Accepted prompts")).lowerBound)
    }

    @MainActor func testAnnotateSelectionEditChipAndSend() {
        continueAfterFailure = false
        let app = launch(); defer { app.terminate() }

        // A short user prompt keeps its ordinary tap and native Copy menu.
        // Paste through the real composer to prove the copied bytes, then leave
        // that composer empty for the selection/annotation journey below.
        let short = app.staticTexts["How should the gateway retry dropped connections?"]
        XCTAssertTrue(short.exists, app.debugDescription)
        short.tap()
        XCTAssertFalse(app.descendants(matching: .any)["home-reading-text"].exists)
        short.press(forDuration: 1)
        let copy = menuAction(app, "Copy")
        XCTAssertTrue(copy.waitForExistence(timeout: 5), app.debugDescription)
        copy.tap()
        let composer = app.textViews["Message input"]
        composer.tap()
        dismissKeyboardTip(app)
        composer.press(forDuration: 1)
        let paste = menuAction(app, "Paste")
        XCTAssertTrue(paste.waitForExistence(timeout: 5), app.debugDescription)
        paste.tap()
        let copied = "How should the gateway retry dropped connections?"
        XCTAssertEqual(composer.value as? String, copied)
        composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: copied.count))
        app.swipeDown()

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
        keepScreenshot(app, "899-3-chips")

        // The chip opens the standard sheet: quote, editable comment, save.
        first.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show annotation'")).firstMatch.tap()
        let editor = commentField(in: app)
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

    /// A long staged comment flows in the sheet itself (#2370): no fixed-height
    /// inner box that scrolls on its own while the sheet below stays empty.
    @MainActor func testLongStagedCommentFlowsInTheSheet() {
        continueAfterFailure = false
        let app = launch(); defer { app.terminate() }
        let paragraph = assistantBlock(app, containing: "exponential backoff")
        paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.12))
            .press(forDuration: 1.0, thenDragTo: paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.83, dy: 0.12)))
        let annotate = menuAction(app, "Annotate")
        XCTAssertTrue(annotate.waitForExistence(timeout: 5), app.debugDescription)
        annotate.tap()
        let bubble = app.otherElements["chat.annotation.bubble"]
        XCTAssertTrue(bubble.waitForExistence(timeout: 5), app.debugDescription)
        dismissKeyboardTip(app)
        let comment = Array(repeating: "Retry with jitter so reconnecting clients do not stampede the Gateway.", count: 8)
            .joined(separator: " ")
        app.typeText(comment)
        app.buttons["Save annotation"].firstMatch.tap()
        XCTAssertTrue(wait(for: bubble, exists: false))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show annotation'")).firstMatch.tap()
        let editor = commentField(in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(editor.value as? String, comment)
        Thread.sleep(forTimeInterval: 0.6)
        keepScreenshot(app, "2370-long-comment-sheet")
        // Eight sentences wrap to over ten lines; the old 120-point box (115 at
        // this sheet's scale) showed five and scrolled the rest inside itself.
        XCTAssertGreaterThan(editor.frame.height, 180, "The comment must take its full height in the sheet: \(editor.frame)")
    }

    /// Saving the bubble hands the keyboard straight to the composer input
    /// (#1597): the chip appears, the keyboard never drops, and the next
    /// keystrokes land in the composer.
    @MainActor func testSavingAnnotationKeepsKeyboardInComposer() {
        continueAfterFailure = false
        let app = launch(); defer { app.terminate() }

        let paragraph = assistantBlock(app, containing: "exponential backoff")
        paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.12))
            .press(forDuration: 1.0, thenDragTo: paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.83, dy: 0.12)))
        let annotate = menuAction(app, "Annotate")
        XCTAssertTrue(annotate.waitForExistence(timeout: 5), app.debugDescription)
        annotate.tap()
        let bubble = app.otherElements["chat.annotation.bubble"]
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "The comment field takes focus")
        dismissKeyboardTip(app)
        app.typeText("Make the cap configurable")

        app.buttons["Save annotation"].firstMatch.tap()
        // Sample from the tap until the chip has settled: the keyboard must be
        // present at every sample, not merely restored afterwards.
        let chips = app.otherElements.matching(identifier: "composer.staged-chip")
        var keyboardSamples: [Bool] = []
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            keyboardSamples.append(keyboard.exists)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        keepScreenshot(app, "1597-after-save")
        XCTAssertFalse(bubble.exists)
        XCTAssertEqual(chips.count, 1, "The annotation becomes a staged chip: \(app.debugDescription)")
        XCTAssertFalse(keyboardSamples.contains(false), "The keyboard stays up through Save: \(keyboardSamples)")
        let composer = app.textViews["Message input"]
        XCTAssertEqual(composer.value(forKey: "hasKeyboardFocus") as? Bool, true, "Focus moves to the composer input")

        app.typeText("Keep typing")
        XCTAssertEqual(composer.value as? String, "Keep typing")
        XCTAssertEqual(chips.count, 1)
    }

    /// Selecting message text while the composer holds the keyboard keeps the
    /// keyboard up and the transcript still, and quotes exactly what the same
    /// gesture quotes with the keyboard down (the control, annotated first),
    /// at the default size and at the largest accessibility size.
    @MainActor func testSelectionWithKeyboardUpKeepsKeyboardAndQuotesSelection() {
        continueAfterFailure = false
        // A line that stays on screen with the keyboard down and up.
        assertKeyboardUpSelectionQuotesSelection(launch(), block: "exponential backoff", line: 0.12)
        assertKeyboardUpSelectionQuotesSelection(
            launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]),
            block: "reconnect notes for the full contract", line: 0.2
        )
    }

    @MainActor private func assertKeyboardUpSelectionQuotesSelection(_ app: XCUIApplication, block: String, line: CGFloat) {
        defer { app.terminate() }
        let keyboard = app.keyboards.firstMatch
        let bubble = app.otherElements["chat.annotation.bubble"]
        let chips = app.otherElements.matching(identifier: "composer.staged-chip")
        let paragraph = assistantBlock(app, containing: block)
        let composer = app.textViews["Message input"]

        func selectLine() {
            paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: line))
                .press(forDuration: 1.0, thenDragTo: paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.83, dy: line)))
        }
        func annotate(_ comment: String) {
            let annotate = menuAction(app, "Annotate")
            XCTAssertTrue(annotate.waitForExistence(timeout: 5), app.debugDescription)
            annotate.tap()
            XCTAssertTrue(bubble.waitForExistence(timeout: 5), app.debugDescription)
            dismissKeyboardTip(app)
            app.typeText(comment)
            app.buttons["Save annotation"].firstMatch.tap()
            XCTAssertTrue(wait(for: bubble, exists: false))
        }

        // Control: the keyboard is down.
        XCTAssertFalse(keyboard.exists)
        selectLine()
        annotate("control")

        // Saving hands the keyboard to the composer (#1597).
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(composer.value(forKey: "hasKeyboardFocus") as? Bool, true)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let restingFrame = paragraph.frame
        selectLine()
        XCTAssertTrue(menuAction(app, "Annotate").waitForExistence(timeout: 5), app.debugDescription)
        keepScreenshot(app, "keyboard-up-selection")
        XCTAssertTrue(keyboard.exists, "Selecting message text keeps the keyboard up")
        XCTAssertEqual(paragraph.frame, restingFrame, "The transcript does not move under the selection")
        annotate("keyboard up")
        XCTAssertTrue(wait { chips.count == 2 }, app.debugDescription)

        func stagedQuote(_ index: Int) -> String {
            chips.element(boundBy: index).buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show annotation'")).firstMatch.tap()
            let quote = app.descendants(matching: .any)["chat.annotation.quote"]
            XCTAssertTrue(quote.waitForExistence(timeout: 5), app.debugDescription)
            let label = quote.label
            app.buttons["Save annotation"].tap()
            XCTAssertTrue(wait(for: quote, exists: false))
            return label
        }
        let control = stagedQuote(0)
        let keyboardUp = stagedQuote(1)
        XCTAssertTrue(control.count > 1 && paragraph.label.contains(control), control)
        XCTAssertEqual(keyboardUp, control, "The keyboard-up selection quotes exactly the selected text")

        // The keyboard-up menu keeps the system Copy, which copies the selection.
        selectLine()
        XCTAssertTrue(menuAction(app, "Annotate").waitForExistence(timeout: 5), app.debugDescription)
        let copy = menuAction(app, "Copy")
        // At accessibility sizes the menu pages after Annotate.
        if !copy.exists { app.buttons["Next Page"].firstMatch.tap() }
        XCTAssertTrue(copy.waitForExistence(timeout: 5), app.debugDescription)
        copy.tap()
        XCTAssertTrue(keyboard.exists)
        composer.press(forDuration: 1)
        let paste = menuAction(app, "Paste")
        XCTAssertTrue(paste.waitForExistence(timeout: 5), app.debugDescription)
        paste.tap()
        XCTAssertTrue(wait { (composer.value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == control },
                      String(describing: composer.value))
    }

    /// Tapping the sheet's quote closes it, scrolls the transcript to the
    /// selected range, even when it has scrolled off screen, and flashes it.
    /// The sent sheet's comment uses the quote's text size (equal text, equal
    /// height), at the default size in dark and light and at the largest
    /// accessibility size.
    @MainActor func testQuoteRevealsSourceAndCommentMatchesQuote() {
        continueAfterFailure = false
        let xxxl = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        for (name, extra) in [("dark", [String]()), ("light", ["-annotation-light"]), ("xxxl", xxxl),
                              ("xxxl-reduce-motion", xxxl + ["-annotation-reduce-motion"])] {
            assertQuoteRevealsSource(launch(extra), name: name)
        }
    }

    @MainActor private func assertQuoteRevealsSource(_ app: XCUIApplication, name: String) {
        defer { app.terminate() }
        let heading = assistantBlock(app, containing: "Retry policy")
        let bubble = app.otherElements["chat.annotation.bubble"]
        let navigationBottom = app.navigationBars.firstMatch.frame.maxY
        // Bring the oldest text into view, annotate the heading with its own
        // words as the comment, then scroll back to the newest end.
        for _ in 0..<4 where heading.frame.minY < navigationBottom { app.swipeDown() }
        heading.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
            .press(forDuration: 1.0, thenDragTo: heading.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)))
        let annotate = menuAction(app, "Annotate")
        XCTAssertTrue(annotate.waitForExistence(timeout: 5), app.debugDescription)
        annotate.tap()
        XCTAssertTrue(bubble.waitForExistence(timeout: 5), app.debugDescription)
        dismissKeyboardTip(app)
        // The comment repeats the quote, so equal sizes give equal heights.
        app.typeText(app.descendants(matching: .any)["chat.annotation.bubble.quote"].label)
        app.buttons["Save annotation"].firstMatch.tap()
        XCTAssertTrue(wait(for: bubble, exists: false))
        let chip = app.otherElements.matching(identifier: "composer.staged-chip").firstMatch
        let catchUp = app.buttons["Catch up"]
        if catchUp.waitForExistence(timeout: 2) { catchUp.tap() }
        // The fixture fits the screen at the default size; at XXXL the source is off screen.
        if name.hasPrefix("xxxl") {
            XCTAssertTrue(wait { heading.frame.maxY < navigationBottom }, "The source scrolled away: \(heading.frame)")
        }

        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show annotation'")).firstMatch.tap()
        let quote = app.descendants(matching: .any)["chat.annotation.quote"]
        let comment = commentField(in: app)
        XCTAssertTrue(quote.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(comment.waitForExistence(timeout: 5), app.debugDescription)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        keepScreenshot(app, "quote-reveal-sheet-\(name)")

        let quoted = quote.label
        quote.tap()
        let flash = app.descendants(matching: .any)["chat.annotation.revealed-source"]
        XCTAssertTrue(flash.waitForExistence(timeout: 5), "The quote reveals its source: \(app.debugDescription)")
        XCTAssertEqual(flash.label, quoted)
        XCTAssertFalse(quote.exists, "The sheet closes to show the source")
        XCTAssertGreaterThanOrEqual(flash.frame.minY, navigationBottom, "Revealed below the navigation bar: \(flash.frame)")
        XCTAssertLessThanOrEqual(flash.frame.maxY, chip.frame.minY, "Revealed above the staged chip: \(flash.frame)")
        keepScreenshot(app, "quote-reveal-source-\(name)")

        // The sent annotation's read-only comment uses the quote's text size.
        app.textViews["Message input"].tap()
        app.typeText("Thanks")
        app.buttons["Send message"].firstMatch.tap()
        // The revealed source leaves the reader detached from the newest end.
        if catchUp.waitForExistence(timeout: 2) { catchUp.tap() }
        let sent = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show annotation'")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 8), app.debugDescription)
        sent.tap()
        let sentComment = app.staticTexts["chat.annotation.comment"]
        XCTAssertTrue(sentComment.waitForExistence(timeout: 5), app.debugDescription)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        keepScreenshot(app, "quote-reveal-sent-sheet-\(name)")
        // Both are selectable Text, whose element frames carry the same inset.
        XCTAssertEqual(sentComment.frame.height, quote.frame.height, accuracy: 1,
                       "The sent comment uses the quote's text size: comment \(sentComment.frame), quote \(quote.frame)")
    }

    /// On iPad, Return in the composer sends exactly like Send, and not while
    /// the composer is empty (uploads: TronComposerUploadUITests). Hardware
    /// Shift+Return and a pasted newline still edit. `typeKey("\n")` is a hardware Return
    /// (XCUIKeyboardKey.return does not reach the field); the on-screen key's
    /// Return is `typeText("\n")`.
    @MainActor func testPadReturnSendsPromptLikeSend() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad keyboard behavior")
        continueAfterFailure = false
        let app = launch(); defer { app.terminate() }
        let composer = app.textViews["Message input"]
        let prompt = app.staticTexts["fixture.last-prompt"]
        composer.tap()
        dismissKeyboardTip(app)

        app.typeText("\n")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(prompt.label, "none", "An empty composer sends nothing")
        XCTAssertEqual(composer.value as? String ?? "", "", "Return in an empty composer inserts nothing")

        composer.typeKey("a", modifierFlags: [])
        composer.typeKey("\n", modifierFlags: .shift)
        composer.typeKey("b", modifierFlags: [])
        XCTAssertEqual((composer.value as? String)?.lowercased(), "a\nb", "Shift+Return inserts a newline")
        UIPasteboard.general.string = "\n"
        composer.press(forDuration: 1)
        let paste = menuAction(app, "Paste")
        XCTAssertTrue(paste.waitForExistence(timeout: 5), app.debugDescription)
        paste.tap()
        XCTAssertTrue(wait { (composer.value as? String)?.lowercased() == "a\nb\n" }, "Pasting a newline inserts it: \(String(describing: composer.value))")
        XCTAssertEqual(prompt.label, "none", "Pasting a newline does not send")
        composer.typeKey("c", modifierFlags: [])
        composer.typeKey("\n", modifierFlags: [])
        XCTAssertTrue(wait { prompt.label.lowercased() == "a\nb\nc" }, prompt.label)
        XCTAssertTrue(wait { (composer.value as? String ?? "").isEmpty }, String(describing: composer.value))
    }

    /// On iPhone, Return keeps inserting a newline in the composer and in the
    /// annotation comment; only Send sends and only the check saves.
    @MainActor func testPhoneReturnInsertsNewline() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone keyboard behavior")
        continueAfterFailure = false
        let app = launch(); defer { app.terminate() }
        let composer = app.textViews["Message input"]
        composer.tap()
        dismissKeyboardTip(app)
        app.typeText("First line\nsecond line")
        XCTAssertEqual(composer.value as? String, "First line\nsecond line")
        XCTAssertEqual(app.staticTexts["fixture.last-prompt"].label, "none")
        composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 22))
        app.swipeDown()

        let bubble = openAnnotationBubble(app)
        app.typeText("Note\nmore")
        XCTAssertEqual(commentField(in: bubble).value as? String, "Note\nmore", app.debugDescription)
        XCTAssertTrue(bubble.exists, "Return does not save on iPhone")
    }

    /// On iPad, the on-screen Return in the annotation bubble saves like the
    /// check and is not kept in the comment.
    @MainActor func testPadReturnSavesAnnotationLikeCheck() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad keyboard behavior")
        continueAfterFailure = false
        let app = launch(); defer { app.terminate() }
        let chips = app.otherElements.matching(identifier: "composer.staged-chip")

        let bubble = openAnnotationBubble(app)
        app.typeText("Make the cap configurable")
        app.typeText("\n")
        XCTAssertTrue(wait(for: bubble, exists: false), "Return saves the annotation")
        XCTAssertTrue(wait { chips.count == 1 }, app.debugDescription)
        assertStagedComment(app, chips.firstMatch, "make the cap configurable", "Return is not part of the comment")
    }

    /// On iPad, a hardware Shift+Return inserts the multi-line comment's newline
    /// at the caret and keeps editing; hardware Return then saves. Hardware keys
    /// go to the first bubble of a launch.
    @MainActor func testPadHardwareShiftReturnAddsLineAndReturnSavesAnnotation() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad keyboard behavior")
        continueAfterFailure = false
        let app = launch(); defer { app.terminate() }
        let chips = app.otherElements.matching(identifier: "composer.staged-chip")

        let bubble = openAnnotationBubble(app)
        app.typeKey("u", modifierFlags: [])
        app.typeKey("p", modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.leftArrow, modifierFlags: [])
        app.typeKey("\n", modifierFlags: .shift)
        app.typeKey("x", modifierFlags: [])
        XCTAssertTrue(bubble.exists, "Shift+Return does not save")
        XCTAssertEqual((commentField(in: bubble).value as? String)?.lowercased(), "u\nxp", "Shift+Return inserts a newline at the caret")
        app.typeKey("\n", modifierFlags: [])
        XCTAssertTrue(wait(for: bubble, exists: false), "Hardware Return saves the annotation")
        XCTAssertTrue(wait { chips.count == 1 }, app.debugDescription)
        assertStagedComment(app, chips.firstMatch, "u\nxp", "Shift+Return keeps its newline")
    }

    @MainActor private func assertStagedComment(_ app: XCUIApplication, _ chip: XCUIElement, _ expected: String,
                                                _ message: String, line: UInt = #line) {
        chip.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show annotation'")).firstMatch.tap()
        let editor = commentField(in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription, line: line)
        XCTAssertEqual((editor.value as? String)?.lowercased(), expected, message, line: line)
    }

    /// The comment field, in the bubble or the sheet; XCUITest types it TextField or TextView.
    @MainActor private func commentField(in container: XCUIElement) -> XCUIElement {
        container.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Annotation comment' AND (elementType == %d OR elementType == %d)",
                                  XCUIElement.ElementType.textView.rawValue, XCUIElement.ElementType.textField.rawValue))
            .firstMatch
    }

    @MainActor private func openAnnotationBubble(_ app: XCUIApplication) -> XCUIElement {
        let paragraph = assistantBlock(app, containing: "exponential backoff")
        paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.12))
            .press(forDuration: 1.0, thenDragTo: paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.83, dy: 0.12)))
        let annotate = menuAction(app, "Annotate")
        XCTAssertTrue(annotate.waitForExistence(timeout: 5), app.debugDescription)
        annotate.tap()
        let bubble = app.otherElements["chat.annotation.bubble"]
        XCTAssertTrue(bubble.waitForExistence(timeout: 5), app.debugDescription)
        dismissKeyboardTip(app)
        return bubble
    }

    @MainActor private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-chat-annotation-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extra
        app.launch()
        XCTAssertTrue(assistantBlock(app, containing: "exponential backoff").waitForExistence(timeout: 20), app.debugDescription)
        return app
    }

    @MainActor private func assistantBlock(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        // Each completed assistant block is its own static-text accessibility
        // element; inside the message's one text view XCUITest types it TextView.
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ AND (elementType == %d OR elementType == %d)",
                                  text, XCUIElement.ElementType.staticText.rawValue, XCUIElement.ElementType.textView.rawValue))
            .firstMatch
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
