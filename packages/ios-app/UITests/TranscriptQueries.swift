import XCTest

extension XCTestCase {
    @MainActor
    func assistantReply(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        assistantReply(app, NSPredicate(format: "label CONTAINS %@", text))
    }

    @MainActor
    func assistantReply(_ app: XCUIApplication, labeled text: String) -> XCUIElement {
        assistantReply(app, NSPredicate(format: "label == %@", text))
    }

    @MainActor
    func inVisualOrder(_ query: XCUIElementQuery) -> [XCUIElement] {
        query.allElementsBoundByIndex.sorted { $0.frame.minY < $1.frame.minY }
    }

    @MainActor
    private func assistantReply(_ app: XCUIApplication, _ predicate: NSPredicate) -> XCUIElement {
        app.textViews.matching(identifier: "chat.assistant.selectable-text")
            .descendants(matching: .any).matching(predicate).firstMatch
    }
}
