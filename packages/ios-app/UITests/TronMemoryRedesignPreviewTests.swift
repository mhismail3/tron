import XCTest

/// Simulator-only visual review capture. Behavioral regressions are added after design approval.
final class TronMemoryRedesignPreviewTests: XCTestCase {
    @MainActor func testLightPreview() throws { try preview(dark: false) }
    @MainActor func testDarkPreview() throws { try preview(dark: true) }

    @MainActor func testLargeTypePreview() throws { try preview(dark: false, large: true) }

    @MainActor private func preview(dark: Bool, large: Bool = false) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-memory-redesign"] + (dark ? ["-home-dark"] : [])
            + (large ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : [])
        app.launch(); defer { app.terminate() }
        let mode = large ? "large" : (dark ? "dark" : "light")
        try ready(app, "home-pinned-row"); shot("\(mode)-dashboard-subtext")
        app.buttons["home-pinned-row"].tap()
        try tap(app, "session-context-button")
        try ready(app, "home-manage-state")
        expand(app, done: "home-sheet-done-manage")
        shot("\(mode)-manage-subtext")
        try reveal(app, "home-manage-memory-browser"); try tap(app, "home-manage-memory-browser")
        try ready(app, "home-memory-row-39")
        expand(app, done: "home-sheet-done-memory")
        shot("\(mode)-memory-rows")
        for (index, name) in [(38, "tool-message"), (37, "tool-call"), (35, "home-message")] {
            try reveal(app, "home-memory-row-\(index)")
            try tap(app, "home-memory-row-\(index)")
            try ready(app, "home-memory-detail")
            expand(app, done: "home-sheet-done-memory-item")
            shot("\(mode)-\(name)")
            if index == 38 {
                let info = app.buttons["home-memory-info"]
                if info.exists {
                    info.tap(); try ready(app, "home-memory-technical-details")
                    shot("\(mode)-technical-details")
                    app.buttons.matching(NSPredicate(format: "label == 'Done'"))
                        .allElementsBoundByIndex.first(where: \.isHittable)?.tap()
                } else { shot("\(mode)-technical-details-unavailable-before") }
                let canonical = element(app, "home-memory-canonical-transcript").exists
                    ? "home-memory-canonical-transcript" : "home-memory-exact-evidence"
                try reveal(app, canonical); try tap(app, canonical)
                try ready(app, "home-evidence-text")
                expand(app, done: "home-sheet-done-evidence")
                shot("\(mode)-canonical-transcript")
                try tap(app, "home-sheet-done-evidence")
            }
            try tap(app, "home-sheet-done-memory-item")
        }
        try reveal(app, "home-memory-summary-32-2")
        try tap(app, "home-memory-summary-32-2")
        try ready(app, "home-memory-summary-detail")
        expand(app, done: "home-sheet-done-memory-summary")
        shot("\(mode)-summary")
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }
    @MainActor private func ready(_ app: XCUIApplication, _ id: String) throws {
        guard element(app, id).waitForExistence(timeout: 5) else {
            let evidence = XCTAttachment(string: app.debugDescription); evidence.name = "missing-\(id)"; evidence.lifetime = .keepAlways; add(evidence)
            throw NSError(domain: "MemoryPreview", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing \(id)"])
        }
    }
    @MainActor private func tap(_ app: XCUIApplication, _ id: String) throws {
        try ready(app, id); element(app, id).tap()
    }
    @MainActor private func reveal(_ app: XCUIApplication, _ id: String) throws {
        for _ in 0..<8 where !element(app, id).isHittable { app.swipeUp() }
        try ready(app, id)
    }
    @MainActor private func expand(_ app: XCUIApplication, done id: String) {
        let done = app.buttons[id].firstMatch
        guard done.exists, done.frame.minY > 120 else { return }
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: 60, dy: done.frame.midY))
            .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: 60, dy: 20)))
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "frame.minY < 120"), object: done)], timeout: 3)
    }
    @MainActor private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "1750-\(name)"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
