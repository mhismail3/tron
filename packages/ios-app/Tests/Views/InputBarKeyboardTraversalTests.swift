import Foundation
import Testing

@Suite("InputBar Keyboard Traversal")
struct InputBarKeyboardTraversalTests {
    @Test("iPad prompt Tab resigns focus instead of entering draft text")
    func testPromptTabResignsFocusInsteadOfEnteringDraftText() throws {
        let source = try Self.inputBarSource()

        #expect(source.contains(".onKeyPress(.tab)"))
        #expect(source.contains("resignInputFocusForKeyboardTraversal()"))
        #expect(source.contains("UIDevice.current.userInterfaceIdiom == .pad"))
        #expect(source.contains("#selector(UIResponder.resignFirstResponder)"))
        #expect(source.contains("return .handled"))
    }

    private static func inputBarSource() throws -> String {
        let fileURL = URL(fileURLWithPath: #filePath)
        let iosRoot = fileURL
            .deletingLastPathComponent() // Views/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // ios-app/
        let sourceURL = iosRoot.appendingPathComponent("Sources/UI/Views/InputBar/InputBar.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
