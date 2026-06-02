import Foundation
import Testing

@Suite("Engine Console Accessibility")
struct EngineConsoleAccessibilityTests {
    @Test("Engine Console chip controls use semantic hoverable buttons")
    func testChipControlsUseSemanticHoverableButtons() throws {
        let source = try Self.source("Sources/Views/EngineConsole/EngineConsoleComponents.swift")
        let sectionChips = try Self.block(
            in: source,
            from: "struct EngineConsoleSectionChips",
            to: "struct EngineConsoleMetric"
        )
        let suggestionChips = try Self.block(
            in: source,
            from: "struct EngineConsoleSuggestionChips",
            to: "struct EngineConsoleMetricGrid"
        )

        Self.expectHoverableChipButtons(sectionChips, minimumOccurrences: 2)
        Self.expectHoverableChipButtons(suggestionChips, minimumOccurrences: 1)
    }

    @Test("dashboard toolbar icon controls have explicit labels and hover affordances")
    func testDashboardToolbarIconControlsStayAccessible() throws {
        let toolbar = try Self.source("Sources/Views/Chat/DashboardToolbarContent.swift")
        let notificationBell = try Self.source("Sources/Views/Notifications/NotificationBellButton.swift")

        #expect(toolbar.contains(#".accessibilityLabel("Show sidebar")"#))
        #expect(toolbar.contains(#".accessibilityLabel("Navigation")"#))
        #expect(toolbar.contains(#".accessibilityLabel("Settings")"#))
        #expect(toolbar.contains(".hoverEffect(.highlight)"))
        #expect(notificationBell.contains(#".accessibilityLabel("Notifications")"#))
        #expect(notificationBell.contains(".accessibilityValue("))
        #expect(notificationBell.contains(".hoverEffect(.highlight)"))
    }

    @Test("harness change evidence card keeps named evidence lanes accessible")
    func testHarnessChangeEvidenceCardStaysAccessible() throws {
        let source = try Self.source("Sources/Views/EngineConsole/EngineConsoleHarnessChangeView.swift")

        for required in [
            "Harness Changes",
            "Provenance",
            "Tests",
            "Generated UI",
            "Promotion",
            "Cleanup",
            "Trace"
        ] {
            #expect(source.contains(required))
        }
        #expect(source.contains(".accessibilityElement(children: .combine)"))
        #expect(source.contains(".accessibilityLabel(change.accessibilityLabel)"))
        #expect(source.contains(".accessibilityValue(change.accessibilityValue)"))
    }

    private static func source(_ relativePath: String) throws -> String {
        let fileURL = URL(fileURLWithPath: #filePath)
        let iosRoot = fileURL
            .deletingLastPathComponent() // Views/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // ios-app/
        return try String(contentsOf: iosRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private static func block(in source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try #require(source.range(of: startMarker))
        let end = try #require(source.range(of: endMarker, range: start.upperBound..<source.endIndex))
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private static func expectHoverableChipButtons(_ source: String, minimumOccurrences: Int) {
        #expect(source.contains("Button {"))
        #expect(source.contains(".buttonStyle(.plain)"))
        #expect(source.contains(".contentShape([.interaction, .hoverEffect], Capsule())"))
        #expect(source.contains(".hoverEffect(.highlight)"))
        #expect(source.contains(".accessibilityElement(children: .combine)"))
        #expect(source.components(separatedBy: ".hoverEffect(.highlight)").count >= minimumOccurrences + 1)
        #expect(source.components(separatedBy: ".accessibilityElement(children: .combine)").count >= minimumOccurrences + 1)
    }
}
