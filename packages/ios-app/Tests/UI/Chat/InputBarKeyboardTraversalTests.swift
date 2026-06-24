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
        let iosRoot = try iosAppRoot()
        let sourceURL = iosRoot.appendingPathComponent("Sources/UI/Chat/Composer/InputBar.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private static func iosAppRoot() throws -> URL {
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("project.yml").path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
