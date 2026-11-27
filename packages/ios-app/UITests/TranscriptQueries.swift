import XCTest

extension XCTestCase {
    @MainActor
    func assistantReply(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.textViews.matching(identifier: "chat.assistant.selectable-text")
            .descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }
}
