import XCTest

/// Native visual review of the restored Manage controls and Settings grouping.
final class TronManageModelPreviewTests: XCTestCase {
    @MainActor func testLightPreview() throws { try preview("light") }
    @MainActor func testDarkPreview() throws { try preview("dark") }
    @MainActor func testLargeTypePreview() throws { try preview("large") }

    @MainActor func testHistoryLargePreview() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-configuration-fixture", "-manage-session-review", "-history-large",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"]
        app.launch(); defer { app.terminate() }
        try tap(app, "Stop session"); try reveal(app, "Session History"); try tap(app, "Session History")
        try ready(app, "history-row-h-6732"); try tap(app, "history-row-h-6732")
        try ready(app, "history-entry-actions")
        let done = app.navigationBars.containing(.staticText, identifier: "History Entry").buttons["Done"].firstMatch
        if done.exists && done.frame.minY > 120 { drag(app, y: done.frame.midY) }
        Thread.sleep(forTimeInterval: 1) // Capture settled sheet chrome, not its entrance transition.
        shot("large-history-entry")
    }

    @MainActor private func preview(_ mode: String) throws {
        let app = XCUIApplication()
        let appearance = mode == "dark" ? ["-home-dark", "-fixture-appearance", "dark"] : ["-fixture-appearance", "light"]
        let type = mode == "large" ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"] : []
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"] + appearance + type
        app.launch(); defer { app.terminate() }
        try tap(app, "home-pinned-row"); try tap(app, "session-context-button")
        try ready(app, "home-manage-state"); expand(app, done: "home-sheet-done-manage")
        shot("\(mode)-manage-home")
        app.swipeUp(); shot("\(mode)-manage-home-lower")
        if app.buttons["manage-model-switch"].exists {
            try reveal(app, "manage-model-switch"); shot("\(mode)-home-model-header")
            app.swipeUp(); shot("\(mode)-home-model-controls")
        }
        try reveal(app, "home-manage-settings"); try tap(app, "home-manage-settings")
        try ready(app, "home-settings-content"); shot("\(mode)-home-settings")
        app.swipeUp(); shot("\(mode)-home-settings-lower")
        app.terminate()
        app.launchArguments = ["-tron-session-configuration-fixture", "-settings-scope-review", "-manage-session-review"] + appearance + type
        app.launch()
        try tap(app, "Stop session"); try ready(app, "manage-session-rename")
        // This fixture opens Manage Session at its default detent.
        let done = app.buttons.matching(NSPredicate(format: "label == 'Done'")) .allElementsBoundByIndex.first(where: \.isHittable)
        if let done, done.frame.minY > 120 { drag(app, y: done.frame.midY) }
        shot("\(mode)-manage-session")
        app.swipeUp(); shot("\(mode)-manage-session-lower")
        if app.buttons["manage-model-switch"].exists {
            try reveal(app, "manage-model-switch"); shot("\(mode)-session-model-header")
            app.swipeUp(); shot("\(mode)-session-model-controls")
        }
        try reveal(app, "chat-settings-link"); try tap(app, "chat-settings-link")
        try ready(app, "session-settings-content"); shot("\(mode)-session-settings")
        app.swipeUp(); shot("\(mode)-session-settings-lower")
    }
    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    @MainActor private func ready(_ app: XCUIApplication, _ id: String) throws {
        guard element(app, id).waitForExistence(timeout: 5) else { throw NSError(domain: "ManagePreview", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing \(id): \(app.debugDescription)"]) }
    }
    @MainActor private func tap(_ app: XCUIApplication, _ id: String) throws { try ready(app, id); element(app, id).tap() }
    @MainActor private func reveal(_ app: XCUIApplication, _ id: String) throws { for _ in 0..<8 where !element(app, id).isHittable { app.swipeUp() }; try ready(app, id) }
    @MainActor private func expand(_ app: XCUIApplication, done id: String) { let done = app.buttons[id]; if done.exists && done.frame.minY > 120 { drag(app, y: done.frame.midY) } }
    @MainActor private func drag(_ app: XCUIApplication, y: CGFloat) {
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: app.frame.width / 2, dy: y)).press(forDuration: 0.1,
            thenDragTo: origin.withOffset(CGVector(dx: app.frame.width / 2, dy: 20)))
    }
    @MainActor private func shot(_ name: String) { let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = "1754-\(name)"; a.lifetime = .keepAlways; add(a) }
}
