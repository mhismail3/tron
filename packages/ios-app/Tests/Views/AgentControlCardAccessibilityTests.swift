import Foundation
import Testing

@Suite("Agent Control Card Accessibility")
struct AgentControlCardAccessibilityTests {
    @Test("tappable Agent Control cards use semantic buttons for pointer and keyboard traversal")
    func testTappableCardsUseSemanticButtonChrome() throws {
        let source = try Self.agentControlCardsSource()

        #expect(source.contains("Button(action: onTap)"))
        #expect(source.contains(".buttonStyle(.plain)"))
        #expect(source.contains(".hoverEffect(.highlight)"))
        #expect(source.contains(".accessibilityElement(children: .combine)"))
        #expect(!source.contains(".onTapGesture(perform: onTap)"))
    }

    private static func agentControlCardsSource() throws -> String {
        let fileURL = URL(fileURLWithPath: #filePath)
        let iosRoot = fileURL
            .deletingLastPathComponent() // Views/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // ios-app/
        let sourceURL = iosRoot.appendingPathComponent("Sources/Views/AgentControl/AgentControlCards.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
