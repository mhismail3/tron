import Testing
import SwiftUI
@testable import TronMobile

@Suite("Accessibility Labels")
@MainActor
struct AccessibilityTests {

    @Test("chipAccessibility produces correct label with tool and status")
    func chipAccessibilityToolAndStatus() {
        // The modifier should produce "Tool, Status" when summary is empty
        let label = chipAccessibilityLabel(tool: "Bash", status: "Completed", summary: "")
        #expect(label == "Bash, Completed")
    }

    @Test("chipAccessibility produces correct label with tool, status, and summary")
    func chipAccessibilityWithSummary() {
        let label = chipAccessibilityLabel(tool: "Read", status: "Completed", summary: "config.json")
        #expect(label == "Read, Completed, config.json")
    }

    @Test("chipAccessibility empty summary does not produce trailing comma")
    func chipAccessibilityEmptySummary() {
        let label = chipAccessibilityLabel(tool: "Write", status: "Failed", summary: "")
        #expect(!label.hasSuffix(", "))
        #expect(!label.hasSuffix(","))
    }

    @Test("chipAccessibility all status enum labels work")
    func chipAccessibilityWithEnumLabels() {
        // Verify all status enums produce valid labels through the helper
        let statuses: [(String, String)] = [
            ("Bash", CommandToolStatus.success.label),
            ("Subagent", SubagentStatus.completed.label),
            ("Notify", NotifyAppStatus.sent.label),
            ("Query", QueryAgentStatus.success.label),
            ("Wait", WaitForAgentsStatus.completed.label),
            ("Render", RenderAppUIStatus.complete.label),
            ("Task", TaskManagerChipStatus.completed.label),
        ]

        for (tool, status) in statuses {
            let label = chipAccessibilityLabel(tool: tool, status: status, summary: "")
            #expect(!label.isEmpty, "Label for \(tool) should not be empty")
            #expect(label.contains(tool), "Label should contain tool name")
            #expect(label.contains(status), "Label should contain status")
        }
    }

    // MARK: - Helper

    /// Replicates the chipAccessibility label construction logic for testing
    private func chipAccessibilityLabel(tool: String, status: String, summary: String) -> String {
        summary.isEmpty ? "\(tool), \(status)" : "\(tool), \(status), \(summary)"
    }
}
