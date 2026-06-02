import Foundation
import Testing

@Suite("Agent Settings Keyboard Traversal")
struct AgentSettingsKeyboardTraversalTests {
    @Test("iPad protected branch field handles Tab as traversal, not branch submit")
    func testProtectedBranchTabResignsFocusWithoutSubmitting() throws {
        let source = try Self.agentSettingsSource()

        #expect(source.contains("@FocusState private var focusedField: AgentSettingsFocusedField?"))
        #expect(source.contains("enum AgentSettingsFocusedField"))
        #expect(source.contains("case protectedBranch"))
        #expect(source.contains(".focused($focusedField, equals: .protectedBranch)"))
        #expect(source.contains(".onKeyPress(.tab)"))
        #expect(source.contains("resignProtectedBranchFocusForKeyboardTraversal()"))
        #expect(source.contains("UIDevice.current.userInterfaceIdiom == .pad"))
        #expect(source.contains("focusedField = nil"))
        #expect(source.contains("#selector(UIResponder.resignFirstResponder)"))
        #expect(source.contains("return .handled"))
        #expect(source.contains("return .ignored"))
    }

    private static func agentSettingsSource() throws -> String {
        let fileURL = URL(fileURLWithPath: #filePath)
        let iosRoot = fileURL
            .deletingLastPathComponent() // Settings/
            .deletingLastPathComponent() // Views/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // ios-app/
        let sourceURL = iosRoot.appendingPathComponent("Sources/Views/Settings/Pages/AgentSettingsPage.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
