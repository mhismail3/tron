import XCTest
import UIKit
import Vision

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
            assertDoneLabelIsPainted(app, done: done, mode: mode)
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
            shot("checkin-\(mode)")
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

    private func assertDoneLabelIsPainted(_ app: XCUIApplication, done: XCUIElement, mode: String) {
        let screenshot = XCUIScreen.main.screenshot().image
        guard let image = screenshot.cgImage else { XCTFail("No actual toolbar screenshot"); return }
        let scale = CGFloat(image.width) / app.frame.width
        let region = done.frame.insetBy(dx: -6, dy: -4)
            .applying(CGAffineTransform(scaleX: scale, y: scale))
        guard let crop = image.cropping(to: region) else { XCTFail("No painted Done region"); return }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        do {
            try VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])
            let words = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let evidence = XCTAttachment(string: "Actual painted Done OCR (\(mode)): \(words)")
            evidence.name = "keyboard-label-\(mode)"; evidence.lifetime = .keepAlways; add(evidence)
            XCTAssertTrue(words.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "done" },
                          "AX can still say Done while the real label is truncated: \(words)")
        } catch { XCTFail("Could not inspect actual toolbar pixels: \(error)") }
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
