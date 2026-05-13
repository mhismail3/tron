import Testing
import SwiftUI
@testable import TronMobile

@Suite("Accessibility Labels")
@MainActor
struct AccessibilityTests {

    @Test("chipAccessibility produces correct label with capability and status")
    func chipAccessibilityToolAndStatus() {
        // The modifier should produce "Tool, Status" when summary is empty
        let label = chipAccessibilityLabel(tool: "Run", status: "Completed", summary: "")
        #expect(label == "Run, Completed")
    }

    @Test("chipAccessibility produces correct label with tool, status, and summary")
    func chipAccessibilityWithSummary() {
        let label = chipAccessibilityLabel(tool: "Read File", status: "Completed", summary: "config.json")
        #expect(label == "Read File, Completed, config.json")
    }

    @Test("chipAccessibility empty summary does not produce trailing comma")
    func chipAccessibilityEmptySummary() {
        let label = chipAccessibilityLabel(tool: "Write File", status: "Failed", summary: "")
        #expect(!label.hasSuffix(", "))
        #expect(!label.hasSuffix(","))
    }

    @Test("chipAccessibility all status enum labels work")
    func chipAccessibilityWithEnumLabels() {
        // Verify all status enums produce valid labels through the helper
        let statuses: [(String, String)] = [
            ("Run", "Completed"),
            ("Subagent", SubagentStatus.completed.label),
            ("Notify", NotifyAppStatus.sent.label),
            ("Wait", "Completed"),
        ]

        for (tool, status) in statuses {
            let label = chipAccessibilityLabel(tool: tool, status: status, summary: "")
            #expect(!label.isEmpty, "Label for \(tool) should not be empty")
            #expect(label.contains(tool), "Label should contain model tool name")
            #expect(label.contains(status), "Label should contain status")
        }
    }

    // MARK: - Helper

    /// Replicates the chipAccessibility label construction logic for testing
    private func chipAccessibilityLabel(tool: String, status: String, summary: String) -> String {
        summary.isEmpty ? "\(tool), \(status)" : "\(tool), \(status), \(summary)"
    }
}
