import XCTest

extension XCTestCase {
    @MainActor
    func assistantReply(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.textViews.matching(identifier: "chat.assistant.selectable-text")
            .descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @MainActor
    func inVisualOrder(_ query: XCUIElementQuery, file: StaticString = #filePath, line: UInt = #line) -> [XCUIElement] {
        let elements = query.allElementsBoundByIndex
        XCTAssertFalse(elements.contains { $0.frame.isEmpty }, "Every element is laid out before it is ordered", file: file, line: line)
        return elements.sorted { $0.frame.minY < $1.frame.minY }
    }
}
