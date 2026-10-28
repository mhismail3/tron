import XCTest

/// Real hosted sheets, unchanged fixture workload on base and candidate. Screenshots
/// are review evidence, not goldens. Geometry assertions exercise the reported seams.
@MainActor final class TronFiveSheetPolishUITests: XCTestCase {
    func testNumericKeyboardToolbar() {
        for mode in ["light", "dark"] {
            let app = launch(mode, fixture: "-tron-mac-settings-fixture", extra: ["-settings-nested"])
            defer { app.terminate() }
            XCTAssertTrue(app.buttons["Open Settings"].waitForExistence(timeout: 10))
            app.buttons["Open Settings"].tap()
            let link = app.buttons["settings-link-App Customizations"]
            reveal(link, app: app)
            link.tap()
            let field = app.textFields["Chats per project"]
            XCTAssertTrue(field.waitForExistence(timeout: 8), app.debugDescription)
            field.tap()
            let done = app.buttons["text-entry-done"]
            XCTAssertTrue(done.waitForExistence(timeout: 5), app.debugDescription)
            shot("keyboard-\(mode)")
            let keyboard = app.keyboards.firstMatch
            XCTAssertTrue(keyboard.exists)
            XCTAssertLessThanOrEqual(done.frame.height, 44, "Keyboard toolbar must use the system control size, not the app glass target")
            XCTAssertLessThanOrEqual(done.frame.width, 100, "Done is an intrinsic toolbar item, not an expanding capsule")
            XCTAssertLessThanOrEqual(done.frame.maxY, keyboard.frame.minY + 1)
            XCTAssertGreaterThanOrEqual(done.frame.minY, keyboard.frame.minY - 60)
            done.tap()
            XCTAssertTrue(wait(keyboard, "exists == false"), "Done dismisses the number pad")
        }
    }

    func testToolsCountSharesHeaderLine() {
        for mode in ["light", "dark"] {
            let app = manage(mode)
            defer { app.terminate() }
            tap(app, "home-manage-settings")
            expandTitle(app, title: "Home Settings")
            let tools = e(app, "settings-row-tools.active")
            reveal(tools, app: app)
            let editor = tools.buttons.matching(NSPredicate(format: "NOT identifier ENDSWITH '-source' AND NOT identifier ENDSWITH '-reset'")).firstMatch
            XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
            editor.tap()
            XCTAssertTrue(e(app, "settings-tools-editor").waitForExistence(timeout: 8), app.debugDescription)
            let title = app.staticTexts["Built-in"].firstMatch
            let count = app.staticTexts["16 of 16 on"].firstMatch
            XCTAssertTrue(title.exists && count.exists, app.debugDescription)
            shot("tools-\(mode)")
            XCTAssertEqual(title.frame.midY, count.frame.midY, accuracy: 3, "Count belongs on the header's baseline")
            XCTAssertGreaterThan(count.frame.minX, title.frame.maxX)
        }
    }

    func testCheckinUsesCompactSpacingAndStandardSubtext() {
        for mode in ["light", "dark"] {
            let app = manage(mode)
            defer { app.terminate() }
            tap(app, "home-manage-tasks")
            expand(app, done: "home-sheet-done-tasks")
            tap(app, "home-task-active")
            expand(app, done: "home-sheet-done-task")
            let card = e(app, "home-task-checkin")
            reveal(card, app: app)
            // Scroll until the complete latest snapshot and its following row are visible.
            let next = e(app, "home-task-checkin-next")
            reveal(next, app: app)
            shot("checkin-\(mode)")
            let title = e(app, "home-task-checkin-summary-title")
            let meta = e(app, "home-task-checkin-summary-subtext")
            let done = e(app, "home-task-checkin-done-title")
            let doneValue = e(app, "home-task-checkin-done-subtext")
            let nextTitle = e(app, "home-task-checkin-next-title")
            XCTAssertTrue(title.exists && meta.exists && done.exists && doneValue.exists && nextTitle.exists, app.debugDescription)
            let standard = e(app, "home-task-checkin-timestamp-title")
            XCTAssertTrue(standard.exists, app.debugDescription)
            XCTAssertEqual(meta.frame.height, standard.frame.height, accuracy: 0.25,
                           "Context uses the same shared subtext token as the timestamp")
            XCTAssertLessThanOrEqual(nextTitle.frame.minY - doneValue.frame.maxY, 12, "Adjacent check-in blocks use shared section/line spacing, not full row insets twice")
            let viewAll = e(app, "home-task-view-checkins")
            reveal(viewAll, app: app)
            let subtitle = viewAll.staticTexts["Every operation and resume"].firstMatch
            XCTAssertTrue(subtitle.exists)
            XCTAssertEqual(subtitle.frame.height, meta.frame.height, accuracy: 0.5)
        }
    }

    func testMemoryBoundaryBalancesCardGaps() {
        for mode in ["light", "dark"] {
            let app = manage(mode)
            defer { app.terminate() }
            tap(app, "home-manage-memory-browser")
            expand(app, done: "home-sheet-done-memory")
            let boundary = e(app, "home-memory-resolution-boundary")
            for _ in 0..<8 {
                if boundary.exists && boundary.isHittable && boundary.frame.maxY < app.frame.maxY - 180 { break }
                app.swipeUp(velocity: .slow)
            }
            // Frame both neighbours without pressing a tappable memory card.
            if boundary.frame.minY < app.frame.height * 0.30 {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.40))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.65)))
            }
            shot("memory-\(mode)")
            let above = e(app, "home-memory-card-34-container")
            let below = e(app, "home-memory-card-32-container")
            XCTAssertTrue(boundary.exists && above.exists && below.exists, app.debugDescription)
            let firstLine = e(app, "home-memory-boundary-title")
            let lastLine = e(app, "home-memory-boundary-subtext")
            XCTAssertTrue(firstLine.exists && lastLine.exists)
            XCTAssertEqual(firstLine.frame.minY - above.frame.maxY, below.frame.minY - lastLine.frame.maxY,
                           accuracy: 1, "The separator's explanatory copy has equal air between the cards on both sides")
        }
    }

    func testModelsKeepOpeningHeightAndRemainInteractive() {
        for mode in ["light", "dark"] {
            let app = manage(mode, extra: ["-five-sheet-model-delay", "-five-sheet-model-catalog"])
            defer { app.terminate() }
            let switcher = app.buttons["manage-model-switch"]
            reveal(switcher, app: app)
            let start = Date()
            switcher.tap()
            let loading = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Loading models…'")).firstMatch
            XCTAssertTrue(loading.waitForExistence(timeout: 2), app.debugDescription)
            // Principal titles also have zero-frame AX bookkeeping nodes;
            // measure the presented sheet's real native toolbar control.
            shot("models-loading-\(mode)")
            XCTAssertTrue(loading.exists, "The opening sample precedes the delayed response")
            guard let openingDone = visibleDone(app) else { XCTFail("No presented sheet toolbar"); return }
            let openingTop = openingDone.frame.minY
            let model = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Claude Opus 5.5'")).firstMatch
            XCTAssertTrue(model.waitForExistence(timeout: 20), app.debugDescription)
            let elapsed = Date().timeIntervalSince(start) * 1000
            // Query again after native geometry settles, without changing a detent.
            XCTAssertTrue(app.buttons["Search models"].waitForExistence(timeout: 5))
            shot("models-\(mode)")
            guard let loadedDone = visibleDone(app) else { XCTFail("No loaded sheet toolbar"); return }
            let loadedTop = loadedDone.frame.minY
            XCTAssertEqual(openingTop, loadedTop, accuracy: 1, "Loading cannot replace the opening detent")
            guard abs(openingTop - loadedTop) <= 1 else {
                let metrics = XCTAttachment(string: "mode=\(mode), controlled_options_delay_ms=12000, tap_to_content_ms=\(elapsed), opening_toolbar_top=\(openingTop), loaded_toolbar_top=\(loadedTop), scroll=not_run_after_geometry_failure")
                metrics.name = "models-measurements-\(mode)"; metrics.lifetime = .keepAlways; add(metrics)
                continue
            }
            let scrollStart = Date()
            let provider = app.buttons.matching(NSPredicate(format: "label CONTAINS '42 models'")).firstMatch
            if provider.exists && provider.value as? String == "Collapsed" { provider.tap() }
            for _ in 0..<4 { app.swipeUp(velocity: .slow) }
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Review Model'")).allElementsBoundByIndex.contains(where: \.isHittable), "Lazy provider rows remain reachable")
            for _ in 0..<4 { app.swipeDown(velocity: .slow) }
            let scrollMS = Date().timeIntervalSince(scrollStart) * 1000
            app.buttons["Search models"].tap()
            let search = app.textFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
            search.tap(); search.typeText("Haiku")
            let haiku = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Claude Haiku 5.5'")).firstMatch
            XCTAssertTrue(haiku.waitForExistence(timeout: 5))
            let metrics = XCTAttachment(string: "mode=\(mode), controlled_options_delay_ms=12000, tap_to_content_ms=\(elapsed), opening_toolbar_top=\(openingTop), loaded_toolbar_top=\(loadedTop), scroll_round_trip_ms=\(scrollMS)")
            metrics.name = "models-measurements-\(mode)"; metrics.lifetime = .keepAlways; add(metrics)
        }
    }

    func testModelsOpenWithoutInjectedDelay() {
        for mode in ["light", "dark"] {
            let app = manage(mode, extra: ["-five-sheet-model-catalog"])
            defer { app.terminate() }
            var samples: [Double] = []
            for _ in 0..<3 {
                let switcher = app.buttons["manage-model-switch"]
                reveal(switcher, app: app)
                let start = Date()
                switcher.tap()
                let opus = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Claude Opus 5.5'")).firstMatch
                XCTAssertTrue(opus.waitForExistence(timeout: 8))
                XCTAssertTrue(app.buttons["Search models"].waitForExistence(timeout: 5))
                samples.append(Date().timeIntervalSince(start) * 1000)
                guard let done = app.buttons.matching(NSPredicate(format: "label == 'Done'")).allElementsBoundByIndex.last(where: \.isHittable) else {
                    XCTFail("Models has no usable Done"); return
                }
                done.tap()
                XCTAssertTrue(switcher.waitForExistence(timeout: 5))
            }
            let metrics = XCTAttachment(string: "mode=\(mode), catalog_models=42, injected_delay_ms=0, tap_to_content_ms=\(samples)")
            metrics.name = "models-no-delay-\(mode)"; metrics.lifetime = .keepAlways; add(metrics)
        }
    }

    private func visibleDone(_ app: XCUIApplication) -> XCUIElement? {
        app.buttons.matching(NSPredicate(format: "label == 'Done'")).allElementsBoundByIndex.last(where: \.isHittable)
    }

    private func launch(_ mode: String, fixture: String, extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = [fixture, "-themeColor", "burgundy", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extra
        if mode == "dark" { app.launchArguments += ["-home-dark", "-settings-renderer-dark"] }
        app.launch()
        return app
    }
    private func manage(_ mode: String, extra: [String] = []) -> XCUIApplication {
        let app = launch(mode, fixture: "-tron-home-dashboard-fixture", extra: ["-home-shell-ready"] + extra)
        tap(app, "home-pinned-row")
        let context = app.buttons["session-context-button"]
        XCTAssertTrue(wait(context, "enabled == true"))
        context.tap()
        XCTAssertTrue(e(app, "home-manage-state").waitForExistence(timeout: 8), app.debugDescription)
        expand(app, done: "home-sheet-done-manage")
        return app
    }
    private func e(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private func tap(_ app: XCUIApplication, _ id: String) {
        let target = e(app, id)
        XCTAssertTrue(target.waitForExistence(timeout: 10), "\(id)\n\(app.debugDescription)")
        reveal(target, app: app)
        target.tap()
    }
    private func reveal(_ target: XCUIElement, app: XCUIApplication) {
        for _ in 0..<8 where !target.isHittable { app.swipeUp(velocity: .slow) }
    }
    private func expand(_ app: XCUIApplication, done id: String) {
        let done = app.buttons[id].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), id)
        guard done.frame.minY > 120 else { return }
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: 60, dy: done.frame.midY)).press(forDuration: 0.1,
            thenDragTo: origin.withOffset(CGVector(dx: 60, dy: 20)))
        _ = wait(done, "frame.minY < 120")
    }
    private func expandTitle(_ app: XCUIApplication, title: String) {
        let bar = app.navigationBars.staticTexts[title].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        guard bar.frame.minY > 120 else { return }
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: 60, dy: bar.frame.midY)).press(forDuration: 0.1,
            thenDragTo: origin.withOffset(CGVector(dx: 60, dy: 20)))
        _ = wait(bar, "frame.minY < 120")
    }
    private func wait(_ element: XCUIElement, _ predicate: String) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)], timeout: 8) == .completed
    }
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "five-\(name)"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
